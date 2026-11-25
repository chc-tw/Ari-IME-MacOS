// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// macOS platform implementation of Ari's per-user data locations.
// Mirrors src/user_data.cpp (Linux/XDG) and wasm/user_data.cpp (MEMFS); the
// portable core never learns about any of these paths.

#include "user_data.h"

#include <chewing.h>

#include <mutex>
#include <set>
#include <cstdlib>
#include <ctime>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#import <Foundation/Foundation.h>

namespace ari_ime {

namespace {

// macOS has no compiled-in /usr/share/libchewing. The dictionary files ship
// inside the application bundle (or next to the command-line tool), so the
// search path is published through libchewing's documented CHEWING_PATH
// environment variable. Doing it here — in the platform data-location file —
// keeps src/zhuyin.cpp free of any macOS-specific branch.
void publishChewingSystemPath() {
    if (const char *existing = std::getenv("CHEWING_PATH");
        existing && *existing) {
        return; // an explicit override (tests, packaging) always wins
    }

    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *resource = [bundle pathForResource:@"tsi" ofType:@"dat"];
        if (resource) {
            setenv("CHEWING_PATH",
                   [[resource stringByDeletingLastPathComponent] UTF8String], 1);
            return;
        }
        // Development / command-line layout: <prefix>/share/libchewing next to
        // the running executable.
        NSString *exec = [[bundle executablePath] stringByDeletingLastPathComponent];
        if (!exec) {
            return;
        }
        NSString *devPath =
            [[exec stringByAppendingPathComponent:@"../share/libchewing"]
                stringByStandardizingPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) {
            setenv("CHEWING_PATH", [devPath UTF8String], 1);
        }
    }
}

std::filesystem::path configuredUserDataDir() {
    // The test harness and the packaging scripts pin the directory explicitly;
    // honour that before anything else so tests never touch real user data.
    if (const char *overrideDir = std::getenv("ARI_IME_USER_DATA_DIR");
        overrideDir && *overrideDir) {
        return std::filesystem::path(overrideDir);
    }

    @autoreleasepool {
        NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            return std::filesystem::path([dirs[0] UTF8String]) / "AriIME";
        }
    }

    if (const char *home = std::getenv("HOME"); home && *home) {
        return std::filesystem::path(home) / "Library" /
               "Application Support" / "AriIME";
    }
    return {};
}

// Sets an environment variable for one scope and restores it afterwards.
class EnvOverride {
public:
    EnvOverride(const char *name, const std::string &value) : name_(name) {
        if (const char *old = std::getenv(name)) {
            old_ = old;
        }
        setenv(name, value.c_str(), 1);
    }
    ~EnvOverride() {
        if (old_) {
            setenv(name_, old_->c_str(), 1);
        } else {
            unsetenv(name_);
        }
    }
    EnvOverride(const EnvOverride &) = delete;
    EnvOverride &operator=(const EnvOverride &) = delete;

private:
    const char *name_;
    std::optional<std::string> old_;
};

void quietLogger(void *, int, const char *, ...) {}

std::vector<std::pair<std::string, std::string>>
enumeratePhrases(ChewingContext *ctx) {
    std::vector<std::pair<std::string, std::string>> out;
    if (!ctx || chewing_userphrase_enumerate(ctx) != 0) {
        return out;
    }
    unsigned int phraseLen = 0;
    unsigned int bopomofoLen = 0;
    while (chewing_userphrase_has_next(ctx, &phraseLen, &bopomofoLen) == 1) {
        if (phraseLen == 0 || bopomofoLen == 0) {
            continue;
        }
        std::vector<char> phrase(phraseLen);
        std::vector<char> bopomofo(bopomofoLen);
        if (chewing_userphrase_get(ctx, phrase.data(), phraseLen,
                                   bopomofo.data(), bopomofoLen) == 0) {
            out.emplace_back(phrase.data(), bopomofo.data());
        }
    }
    return out;
}

// An install that already split (see userDictionaryPath) has phrases in
// userdict.dat that no context uses. Move them into chewing.dat once, and keep the old file as a
// backup so the same phrases are not merged again — or brought back after
// the user deletes them.
void mergeSplitLegacyDictionary(const std::filesystem::path &dir) {
    static std::mutex mutex;
    static std::set<std::string> checked;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (!checked.insert(dir.string()).second) {
            return;
        }
    }
    const std::filesystem::path legacy = dir / "userdict.dat";
    const std::filesystem::path standard = dir / "chewing.dat";
    std::error_code ec;
    if (!std::filesystem::exists(legacy, ec) ||
        !std::filesystem::exists(standard, ec)) {
        return;
    }

    std::vector<std::pair<std::string, std::string>> phrases;
    {
        // Point the data directory somewhere empty so chewing.dat is not
        // found and userdict.dat is the only user dictionary of this context.
        const EnvOverride userPath("CHEWING_USER_PATH",
                                   (dir / ".no-such-dir").string());
        ChewingContext *ctx =
            chewing_new2(nullptr, legacy.c_str(), quietLogger, nullptr);
        phrases = enumeratePhrases(ctx);
        if (ctx) {
            chewing_delete(ctx);
        }
    }
    if (phrases.empty()) {
        return;
    }
    {
        const EnvOverride userPath("CHEWING_USER_PATH", dir.string());
        ChewingContext *ctx =
            chewing_new2(nullptr, standard.c_str(), quietLogger, nullptr);
        if (!ctx) {
            return; // leave userdict.dat in place and try again next launch
        }
        for (const auto &[phrase, reading] : phrases) {
            if (chewing_userphrase_lookup(ctx, phrase.c_str(), reading.c_str()) != 1) {
                chewing_userphrase_add(ctx, phrase.c_str(), reading.c_str());
            }
        }
        chewing_delete(ctx);
    }
    const std::filesystem::path backup =
        dir / ("userdict.dat.merged-" + std::to_string(std::time(nullptr)) + ".bak");
    std::filesystem::rename(legacy, backup, ec);
}

} // namespace

std::filesystem::path userDataDir() { return configuredUserDataDir(); }

// libchewing 0.13 writes to (and lists) the first user dictionary it loads,
// and it finds chewing.dat in the data directory before any other file passed
// as the user path. Upstream passes userdict.dat, so on a fresh install the
// first context wrote there while every later one wrote to chewing.dat, and a
// custom phrase could be saved where nothing read it (D18). Passing chewing.dat
// itself makes libchewing load it once, as the only user dictionary.
std::filesystem::path userDictionaryPath() {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        return {};
    }
    return dir / "chewing.dat";
}

std::filesystem::path userPreferencePath() {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        return {};
    }
    return dir / "preferences.tsv";
}

bool autoLearnEnabled() {
    return std::getenv("ARI_IME_DISABLE_AUTOLEARN") == nullptr;
}

bool ensureUserDataDir(std::error_code &ec) {
    publishChewingSystemPath();

    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        ec = std::make_error_code(std::errc::no_such_file_or_directory);
        return false;
    }
    std::filesystem::create_directories(dir, ec);
    if (ec) {
        return false;
    }

    // chewing.dat is the user dictionary (see userDictionaryPath). Data from a
    // build that only wrote userdict.dat is carried over by copying it, as the
    // Linux build does; a split install is merged below.
    const std::filesystem::path legacy = dir / "userdict.dat";
    const std::filesystem::path standard = dir / "chewing.dat";
    std::error_code inspectEc;
    if (!std::filesystem::exists(standard, inspectEc) && !inspectEc &&
        std::filesystem::exists(legacy, inspectEc) && !inspectEc) {
        std::filesystem::copy_file(legacy, standard,
                                   std::filesystem::copy_options::none, ec);
        if (ec == std::errc::file_exists) {
            ec.clear();
        }
    }
    if (ec) {
        return false;
    }
    mergeSplitLegacyDictionary(dir);
    return true;
}

bool resetUserDictionary(std::error_code &ec) {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        ec = std::make_error_code(std::errc::no_such_file_or_directory);
        return false;
    }

    const std::filesystem::path paths[] = {
        dir / "userdict.dat",
        dir / "chewing.dat",
        dir / "chewing-deleted.dat",
        dir / "preferences.tsv",
        dir / "pick-memory.tsv", // D19
    };
    ec.clear();
    for (const auto &path : paths) {
        std::filesystem::remove(path, ec);
        if (ec) {
            return false;
        }
    }
    return !ec;
}

} // namespace ari_ime

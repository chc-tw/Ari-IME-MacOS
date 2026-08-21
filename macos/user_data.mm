// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// macOS platform implementation of Ari's per-user data locations.
// Mirrors src/user_data.cpp (Linux/XDG) and wasm/user_data.cpp (MEMFS); the
// portable core never learns about any of these paths.

#include "user_data.h"

#include <cstdlib>
#include <string>

#import <Foundation/Foundation.h>

namespace inputer {

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
    if (const char *overrideDir = std::getenv("INPUTER_USER_DATA_DIR");
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

} // namespace

std::filesystem::path userDataDir() { return configuredUserDataDir(); }

std::filesystem::path userDictionaryPath() {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        return {};
    }
    return dir / "userdict.dat";
}

std::filesystem::path userPreferencePath() {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        return {};
    }
    return dir / "preferences.tsv";
}

bool autoLearnEnabled() {
    return std::getenv("INPUTER_DISABLE_AUTOLEARN") == nullptr;
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

    // Same non-destructive migration as the Linux build: libchewing 0.12 reads
    // chewing.dat from CHEWING_USER_PATH even when Ari passes its historical
    // userdict.dat explicitly.
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
    return !ec;
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

} // namespace inputer

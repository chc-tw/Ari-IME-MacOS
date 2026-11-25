// SPDX-License-Identifier: GPL-3.0-or-later
// Custom phrases must land in the user dictionary every context reads (D18).
//
// libchewing writes to the first user dictionary it loads, and finds
// chewing.dat in the data directory before the userdict.dat Ari passes. On a
// fresh install the first context used to write to userdict.dat while later
// ones wrote to chewing.dat, so a phrase could be saved where nothing read it.

#include "buffer.h"
#include "user_data.h"
#include "zhuyin.h"

#include <chewing.h>
#include <fcitx-utils/keysym.h>

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <unistd.h>

#import <Foundation/Foundation.h>

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const char *label) {
    ++checks;
    if (!condition) {
        ++failures;
        std::printf("FAIL %s\n", label);
    }
}

bool listed(const std::string &phrase) {
    Zhuyin dictionary; // a fresh context, as the preferences window opens
    for (const auto &entry : dictionary.userPhrases()) {
        if (entry.phrase == phrase) {
            return true;
        }
    }
    return false;
}

void type(Buffer &buffer, const std::string &keys) {
    for (char c : keys) {
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>(c)));
    }
}

std::filesystem::path useFreshDir(const char *name) {
    const std::filesystem::path dir =
        std::filesystem::temp_directory_path() /
        (std::string("ari-userdict-test-") + name + "-" + std::to_string(getpid()));
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
    setenv("ARI_IME_USER_DATA_DIR", dir.c_str(), 1);
    return dir;
}

void quiet(void *, int, const char *, ...) {}

} // namespace

int main() {
    @autoreleasepool {
        { // Fresh install: a phrase added with Shift+← and Enter is in the
          // dictionary a new context reads, and converts there.
            useFreshDir("fresh");
            {
                Buffer buffer;
                type(buffer, "zj6g4");
                const std::string shown = buffer.preeditText();
                buffer.handleKey(fcitx::Key(FcitxKey_End));
                for (int i = 0; i < 2; ++i) {
                    buffer.handleKey(fcitx::Key(FcitxKey_Left,
                                                fcitx::KeyStates(fcitx::KeyState::Shift)));
                }
                buffer.handleKey(fcitx::Key(FcitxKey_Return));
                check(listed(shown), "a phrase added on a fresh install is listed");
            }
        }

        { // An install that already split: a phrase only in userdict.dat is
          // merged into chewing.dat, and the old file is kept as a backup.
            const std::filesystem::path dir = useFreshDir("split");
            std::filesystem::create_directories(dir);
            const std::filesystem::path legacy = dir / "userdict.dat";
            {
                // An empty chewing.dat, as the copy made on a split install.
                setenv("CHEWING_USER_PATH", dir.c_str(), 1);
                ChewingContext *ctx = chewing_new2(
                    nullptr, (dir / "chewing.dat").c_str(), quiet, nullptr);
                check(ctx != nullptr, "the standard context opens");
                chewing_delete(ctx);
                unsetenv("CHEWING_USER_PATH");
            }
            {
                // Write the phrase into userdict.dat alone, as the first
                // context of a split install did.
                const std::string none = (dir / ".none").string();
                setenv("CHEWING_USER_PATH", none.c_str(), 1);
                ChewingContext *ctx = chewing_new2(nullptr, legacy.c_str(), quiet, nullptr);
                check(ctx != nullptr, "the legacy context opens");
                chewing_userphrase_add(ctx, "福試", "ㄈㄨˊ ㄕˋ");
                chewing_delete(ctx);
                unsetenv("CHEWING_USER_PATH");
            }
            check(std::filesystem::exists(dir / "chewing.dat"),
                  "setup: chewing.dat exists without the phrase");
            check(listed("福試"), "the split phrase is merged and listed");
            bool backedUp = false;
            for (const auto &entry : std::filesystem::directory_iterator(dir)) {
                backedUp |= entry.path().filename().string().rfind(
                                "userdict.dat.merged-", 0) == 0;
            }
            check(backedUp, "userdict.dat is kept as a backup");
            Buffer buffer;
            type(buffer, "zj6g4");
            check(buffer.preeditText() == "福試", "and the merged phrase converts");
        }
    }
    std::printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}

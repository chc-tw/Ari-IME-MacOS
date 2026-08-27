// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Where the English/Chinese boundary lands. Upstream's test/test_buffer.cpp
// stays the untouched baseline; the expectations that this fork deliberately
// changed live here, next to the cases they must not break.
//
// Layout is 大千 throughout: c=ㄏ j=ㄨ 0=ㄢ 6=ˊ | r=ㄐ u=ㄧ ,=ㄝ 8=ㄚ
//                          x=ㄌ .=ㄡ | s=ㄋ 3=ˇ | v=ㄒ ;=ㄤ 4=ˋ | _ = Space
#include <cstdio>
#include <string>

#import <Foundation/Foundation.h>

#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>

#include "buffer.h"
#include "unicode.h"

static int failures = 0;
static int checks = 0;

namespace {

std::string typeKeys(const char *keys) {
    Buffer buffer;
    for (const char *p = keys; *p; ++p) {
        buffer.handleKey(*p == '_'
                             ? fcitx::Key(FcitxKey_space)
                             : fcitx::Key(static_cast<fcitx::KeySym>(
                                   static_cast<unsigned char>(*p))));
    }
    return buffer.preeditText();
}

// The exact character depends on libchewing's ranking, which moves between
// dictionary releases. What this file pins is the boundary: how much of the
// English run survives, and how many characters the Chinese part became.
void checkBoundary(const char *keys, const char *english, int chineseChars,
                   const char *label) {
    ++checks;
    const std::string preedit = typeKeys(keys);
    const auto graphemes = ari_ime::unicode::splitGraphemes(preedit);
    const bool prefixOk = preedit.rfind(english, 0) == 0;
    const int total = static_cast<int>(graphemes.size());
    const int expected =
        static_cast<int>(ari_ime::unicode::splitGraphemes(english).size()) +
        chineseChars;
    if (!prefixOk || total != expected) {
        ++failures;
        printf("FAIL %-44s got=\"%s\" want \"%s\" + %d Chinese\n", label,
               preedit.c_str(), english, chineseChars);
    }
}

} // namespace

int main() {
    @autoreleasepool {
        NSString *sandbox = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"ari-mixed-input-test"];
        setenv("ARI_IME_USER_DATA_DIR", sandbox.UTF8String, 1);
        setenv("CHEWING_USER_PATH", sandbox.UTF8String, 1);
        setenv("ARI_IME_DISABLE_AUTOLEARN", "1", 1);

        // --- The reported failures: the initial was being stranded ---------
        // "ui" is a valid Bopomofo body (ㄧㄛ), so the ㄏ that follows used to
        // collide, flip the run to English and take the ㄏ with it.
        checkBoundary("uicj06", "ui", 1, "ui + ㄏㄨㄢˊ keeps ui English");
        checkBoundary("uicj06ru,6", "ui", 2, "ui + two syllables");
        // The shortest peel left the ㄌ behind in "agentx".
        checkBoundary("agentxu.6", "agent", 1, "agent + ㄌㄧㄡˊ keeps agent whole");
        // Any literal character had the same effect, punctuation included.
        checkBoundary("?vu;4", "?", 1, "? + ㄒㄧㄤˋ keeps the ㄒ");
        checkBoundary("avu;4", "a", 1, "a + ㄒㄧㄤˋ keeps the ㄒ");
        // Space is 一聲, and had no general peel at all: nothing converted.
        checkBoundary("shiftru8_", "shift", 1, "shift + ㄐㄧㄚ via Space");
        checkBoundary("c8_c8_cc8_", "", 4, "哈哈 + c + 哈 via Space");

        // --- What the shortest-peel rule protects, and must keep -----------
        // "ru/6" is initial-led but ㄐㄩㄥˊ is not a character, so this falls
        // through to the shortest peel and "acer" survives.
        checkBoundary("aceru/6", "acer", 1, "acer + ㄧㄥˊ stays acer");
        // "psu3" starts at a final (ㄣ), so it is never considered.
        checkBoundary("HTTPsu3", "HTTP", 1, "HTTP + ㄋㄧˇ stays HTTP");
        // Nothing to peel from.
        checkBoundary("su3", "", 1, "a bare syllable");
        checkBoundary("README.md", "README.md", 0, "plain English is untouched");

        [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
        printf("\n%d checks, %d failures\n", checks, failures);
        return failures == 0 ? 0 : 1;
    }
}

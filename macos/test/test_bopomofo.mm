// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
// The reading shown beside the raw keys of a syllable in progress.
#include <cstdio>
#include <string>

#import <Foundation/Foundation.h>

#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>

#include "AriBopomofo.h"
#include "buffer.h"
#include "layout.h"

static int failures = 0;
static int checks = 0;

static void checkEq(const std::string &actual, const std::string &expected,
                    const char *label) {
    ++checks;
    if (actual != expected) {
        ++failures;
        printf("FAIL %-46s got=\"%s\" want=\"%s\"\n", label, actual.c_str(),
               expected.c_str());
    }
}

namespace {

struct Sim {
    Buffer buffer;
    void type(const std::string &keys) {
        for (char c : keys) {
            buffer.handleKey(
                fcitx::Key(static_cast<fcitx::KeySym>(static_cast<unsigned char>(c))));
        }
    }
    // What the frontend would show beside the pre-edit.
    std::string reading() {
        return ari::readingForKeys(buffer.pendingSyllable());
    }
};

} // namespace

int main() {
    @autoreleasepool {
        NSString *sandbox = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"ari-bopomofo-test"];
        setenv("INPUTER_USER_DATA_DIR", sandbox.UTF8String, 1);
        setenv("CHEWING_USER_PATH", sandbox.UTF8String, 1);
        setenv("INPUTER_DISABLE_AUTOLEARN", "1", 1);

        // Raw keys render as the reading they stand for.
        checkEq(ari::readingForKeys("c"), "ㄏ", "c is ㄏ");
        checkEq(ari::readingForKeys("cj"), "ㄏㄨ", "cj is ㄏㄨ");
        checkEq(ari::readingForKeys("cj0"), "ㄏㄨㄢ", "cj0 is ㄏㄨㄢ");
        checkEq(ari::readingForKeys("su"), "ㄋㄧ", "su is ㄋㄧ");
        checkEq(ari::readingForKeys(""), "", "no keys, no reading");

        // Driven from the buffer, which is how the frontend uses it.
        { Sim s; s.type("cj0"); checkEq(s.reading(), "ㄏㄨㄢ", "buffer: cj0"); }
        { Sim s; s.type("su"); checkEq(s.reading(), "ㄋㄧ", "buffer: su"); }

        // A completed syllable has nothing pending: the character speaks for
        // itself.
        { Sim s; s.type("su3"); checkEq(s.reading(), "", "su3 converted, nothing pending"); }

        // This is the case the display exists for: "ui" looks like English but
        // Ari is reading it as ㄧㄛ, and the user can now see that.
        { Sim s; s.type("ui"); checkEq(s.reading(), "ㄧㄛ", "ui is being read as ㄧㄛ"); }

        // An English run that is not a syllable shows nothing.
        { Sim s; s.type("acer"); checkEq(s.reading(), "", "acer is English, no reading"); }
        { Sim s; s.type("agent"); checkEq(s.reading(), "", "agent is English, no reading"); }

        [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
        printf("\n%d checks, %d failures\n", checks, failures);
        return failures == 0 ? 0 : 1;
    }
}

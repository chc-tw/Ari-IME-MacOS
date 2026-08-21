// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
// Verifies that the NSUserDefaults keys and their enum encodings match the
// Fcitx5 addon's option names, so both platforms are configured the same way.
#include <cstdio>

#import <Foundation/Foundation.h>

#include "AriPreferences.h"

static int failures = 0;
static int checks = 0;

static void check(bool condition, const char *label) {
    ++checks;
    if (!condition) {
        ++failures;
        printf("FAIL %s\n", label);
    }
}

int main() {
    @autoreleasepool {
        NSString *suite = @"io.github.chctw.inputmethod.AriIME.test";
        NSUserDefaults *defaults =
            [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];

        { // Nothing set: the Fcitx5 defaults, plus the macOS arrow style.
            const ari::Preferences p = ari::currentPreferences((__bridge void *)defaults);
            check(p.layout == inputer::KeyboardLayout::Default, "default layout");
            check(!p.fullWidthPunctuation, "default half-width punctuation");
            check(p.punctuationShortcut ==
                      inputer::ChinesePunctuationShortcut::ControlShift,
                  "default punctuation shortcut is Ctrl+Shift");
            check(!p.spaceCandidateMode, "SpaceCandidateMode off by default");
            check(p.autoLearn, "AutoLearn on by default");
            check(!p.showStatusLine, "ShowStatusLine off by default");
            check(p.arrowStyle == ari::ArrowStyle::MacOS,
                  "arrows follow macOS convention by default");
        }

        { // Enums decode from the same strings the Fcitx5 config uses.
            [defaults setObject:@"Eten" forKey:@"KeyboardLayout"];
            [defaults setObject:@"AltShift" forKey:@"ChinesePunctuationShortcut"];
            [defaults setBool:YES forKey:@"FullWidthPunctuation"];
            [defaults setBool:NO forKey:@"AutoLearn"];
            [defaults setBool:YES forKey:@"ShowStatusLine"];
            [defaults setObject:@"Linux" forKey:@"CandidateArrowKeys"];
            const ari::Preferences p = ari::currentPreferences((__bridge void *)defaults);
            check(p.layout == inputer::KeyboardLayout::Eten, "layout reads Eten");
            check(p.punctuationShortcut ==
                      inputer::ChinesePunctuationShortcut::AltShift,
                  "punctuation shortcut reads AltShift");
            check(p.fullWidthPunctuation, "FullWidthPunctuation reads true");
            check(!p.autoLearn, "AutoLearn reads false");
            check(p.showStatusLine, "ShowStatusLine reads true");
            check(p.arrowStyle == ari::ArrowStyle::Linux,
                  "CandidateArrowKeys reads Linux");
        }

        { // Garbage falls back instead of throwing the input method off.
            [defaults setObject:@"NotALayout" forKey:@"KeyboardLayout"];
            [defaults setObject:@"Nonsense" forKey:@"CandidateArrowKeys"];
            const ari::Preferences p = ari::currentPreferences((__bridge void *)defaults);
            check(p.layout == inputer::KeyboardLayout::Default,
                  "unknown layout falls back to Default");
            check(p.arrowStyle == ari::ArrowStyle::MacOS,
                  "unknown arrow style falls back to macOS");
        }

        [defaults removePersistentDomainForName:suite];
        printf("\n%d checks, %d failures\n", checks, failures);
        return failures == 0 ? 0 : 1;
    }
}

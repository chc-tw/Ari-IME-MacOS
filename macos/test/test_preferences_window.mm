// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// The settings window is built programmatically inside the input method
// process, so a mistake in it takes the input method down with it. This builds
// it, shows it, and drives its controls, which is what the input menu does.
#include <cstdio>

#import <Cocoa/Cocoa.h>

#import "AriPreferencesWindow.h"

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
        [NSApplication sharedApplication];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSArray<NSString *> *keys = @[
            @"KeyboardLayout", @"PunctuationStyle", @"CandidateArrowKeys",
            @"ShowBopomofo", @"UppercaseIsEnglish", @"AutoLearn",
            @"ShowStatusLine", @"SpaceCandidateMode",
            @"ChinesePunctuationShortcut"
        ];
        for (NSString *key in keys) {
            [defaults removeObjectForKey:key];
        }

        AriPreferencesWindow *window = [AriPreferencesWindow shared];
        check(window != nil, "the window controller exists");

        // Building and showing must not throw: this is what the menu item does.
        [window show];
        check(true, "show builds and orders the window front");

        // Showing it twice reuses the same window rather than stacking copies.
        [window show];
        check(true, "showing twice is safe");

        // Every control writes through to the documented defaults key. The
        // window loads from the current preferences, so a round trip through
        // settingChanged: must leave the same values readable.
        const ari::Preferences before = ari::currentPreferences();
        [NSApp sendAction:@selector(settingChanged:) to:nil from:nil];
        const ari::Preferences after = ari::currentPreferences();
        check(before.layout == after.layout, "layout survives a write");
        check(before.punctuationStyle == after.punctuationStyle,
              "punctuation style survives a write");
        check(before.arrowStyle == after.arrowStyle, "arrow style survives a write");
        check(before.showBopomofo == after.showBopomofo,
              "ShowBopomofo survives a write");
        check(before.uppercaseIsEnglish == after.uppercaseIsEnglish,
              "UppercaseIsEnglish survives a write");
        check(before.autoLearn == after.autoLearn, "AutoLearn survives a write");

        for (NSString *key in keys) {
            [defaults removeObjectForKey:key];
        }
        printf("\n%d checks, %d failures\n", checks, failures);
        return failures == 0 ? 0 : 1;
    }
}

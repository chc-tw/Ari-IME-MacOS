// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#include "AriPreferences.h"

#import <Foundation/Foundation.h>

#include <fcitx-config/rawconfig.h>

#include <string>

namespace ari {

namespace {

// Keys match the Fcitx5 addon's option names, so the two platforms document
// and troubleshoot the same way:
//   defaults write io.github.chctw.inputmethod.AriIME KeyboardLayout Eten
NSString *const kKeyboardLayout = @"KeyboardLayout";
NSString *const kPunctuationStyle = @"PunctuationStyle";
NSString *const kChinesePunctuationShortcut = @"ChinesePunctuationShortcut";
NSString *const kSpaceCandidateMode = @"SpaceCandidateMode";
NSString *const kAutoLearn = @"AutoLearn";
NSString *const kShowStatusLine = @"ShowStatusLine";
NSString *const kShowBopomofo = @"ShowBopomofo";
NSString *const kCandidateArrowKeys = @"CandidateArrowKeys";

bool boolOr(NSUserDefaults *defaults, NSString *key, bool fallback) {
    return [defaults objectForKey:key] ? [defaults boolForKey:key] : fallback;
}

// Enum values are stored as the same strings the Fcitx5 config uses, decoded
// through the shared unmarshallOption helper.
template <typename Enum>
Enum enumOr(NSUserDefaults *defaults, NSString *key, Enum fallback) {
    NSString *value = [defaults stringForKey:key];
    if (value.length == 0) {
        return fallback;
    }
    fcitx::RawConfig raw;
    raw.setValue(value.UTF8String ?: "");
    Enum parsed = fallback;
    return unmarshallOption(parsed, raw, false) ? parsed : fallback;
}

} // namespace

Preferences currentPreferences(void *defaultsOrNil) {
    Preferences preferences;
    NSUserDefaults *defaults = defaultsOrNil
                                   ? (__bridge NSUserDefaults *)defaultsOrNil
                                   : NSUserDefaults.standardUserDefaults;

    preferences.layout =
        enumOr(defaults, kKeyboardLayout, preferences.layout);
    if (!inputer::keyboardLayoutAvailable(preferences.layout)) {
        preferences.layout = inputer::KeyboardLayout::Default;
    }
    NSString *punctuation = [defaults stringForKey:kPunctuationStyle];
    if ([punctuation isEqualToString:@"English"]) {
        preferences.punctuationStyle = PunctuationStyle::English;
    } else if ([punctuation isEqualToString:@"Chinese"]) {
        preferences.punctuationStyle = PunctuationStyle::Chinese;
    }
    preferences.punctuationShortcut = enumOr(defaults, kChinesePunctuationShortcut,
                                             preferences.punctuationShortcut);
    preferences.spaceCandidateMode =
        boolOr(defaults, kSpaceCandidateMode, preferences.spaceCandidateMode);
    preferences.autoLearn = boolOr(defaults, kAutoLearn, preferences.autoLearn);
    preferences.showStatusLine =
        boolOr(defaults, kShowStatusLine, preferences.showStatusLine);
    preferences.showBopomofo =
        boolOr(defaults, kShowBopomofo, preferences.showBopomofo);

    NSString *arrows = [defaults stringForKey:kCandidateArrowKeys];
    if ([arrows isEqualToString:@"Linux"]) {
        preferences.arrowStyle = ArrowStyle::Linux;
    } else if ([arrows isEqualToString:@"MacOS"]) {
        preferences.arrowStyle = ArrowStyle::MacOS;
    }
    return preferences;
}

} // namespace ari

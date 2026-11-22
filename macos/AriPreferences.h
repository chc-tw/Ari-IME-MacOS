// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// The macOS equivalent of the Fcitx5 addon configuration. Same options, same
// defaults, same stable string values for the enums (the compat layer's
// FCITX_CONFIG_ENUM_NAME marshalling is shared with layout.h), stored in
// NSUserDefaults instead of an ini file.
#ifndef ARI_MACOS_PREFERENCES_H
#define ARI_MACOS_PREFERENCES_H

#include "layout.h"

namespace ari {

// What ←/→ do while the candidate window is open. The core only knows the
// Linux behavior; KeyMap translates for the macOS one.
// Which punctuation a bare punctuation key produces while composing Chinese.
enum class PunctuationStyle {
    // 「」，。？！ etc., matching the system Bopomofo input method. Symbols a
    // programmer types inside Chinese text (@ # $ % & * + = _ ` |) stay
    // half-width; switch to English mode for half-width punctuation.
    Chinese,
    // Everything stays literal and half-width, as upstream does.
    English,
};

enum class ArrowStyle {
    MacOS, // ←/→ page the list, ⌥←/⌥→ move between characters
    Linux, // ←/→ move between characters, PageUp/PageDown page the list
};

struct Preferences {
    ari_ime::KeyboardLayout layout = ari_ime::KeyboardLayout::Default;
    PunctuationStyle punctuationStyle = PunctuationStyle::Chinese;
    ari_ime::ChinesePunctuationShortcut punctuationShortcut =
        ari_ime::ChinesePunctuationShortcut::ControlShift;
    bool spaceCandidateMode = false;
    bool autoLearn = true;
    bool showStatusLine = false;
    // Show the reading of the syllable being composed (ㄏㄨㄢ) next to the raw
    // keys the pre-edit shows. On by default: it is what makes a mis-parsed
    // English/Chinese boundary visible while typing.
    bool showBopomofo = true;
    // Uppercase letters are English, never 注音. On by default: a capital in
    // the middle of Chinese is nearly always an acronym or an identifier.
    bool uppercaseIsEnglish = true;
    // ⌘Return picks a candidate and leaves the caret where it was, instead of
    // returning it to the end of the composition. On by default.
    bool caretStaysAfterPick = true;
    // ↑ on a page's first candidate and ↓ on its last wrap within the page,
    // rather than moving to the previous or next page. On by default.
    bool candidateWrapWithinPage = true;
    ArrowStyle arrowStyle = ArrowStyle::MacOS;
};

// Reads the current values from NSUserDefaults, falling back to the defaults
// above for anything unset or unrecognised. `defaults` is for tests; nil means
// the standard user defaults.
Preferences currentPreferences(void *defaults = nullptr);

} // namespace ari

#endif // ARI_MACOS_PREFERENCES_H

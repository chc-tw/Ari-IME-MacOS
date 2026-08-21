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
enum class ArrowStyle {
    MacOS, // ←/→ page the list, ⌥←/⌥→ move between characters
    Linux, // ←/→ move between characters, PageUp/PageDown page the list
};

struct Preferences {
    inputer::KeyboardLayout layout = inputer::KeyboardLayout::Default;
    bool fullWidthPunctuation = false;
    inputer::ChinesePunctuationShortcut punctuationShortcut =
        inputer::ChinesePunctuationShortcut::ControlShift;
    bool spaceCandidateMode = false;
    bool autoLearn = true;
    bool showStatusLine = false;
    ArrowStyle arrowStyle = ArrowStyle::MacOS;
};

// Reads the current values from NSUserDefaults, falling back to the defaults
// above for anything unset or unrecognised. `defaults` is for tests; nil means
// the standard user defaults.
Preferences currentPreferences(void *defaults = nullptr);

} // namespace ari

#endif // ARI_MACOS_PREFERENCES_H

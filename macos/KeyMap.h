// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Translate macOS key events into the fcitx::Key values the portable Buffer
// expects. This is deliberately a pure function of (virtual key code, the
// characters the key would produce ignoring Command/Control/Option, modifier
// bits) so it can be unit tested without AppKit.
//
// It is also where Ari's macOS shortcut defaults live. The core hard-codes
// Ctrl+Space (中/英) and Alt+[ / Alt+] (corner quotes), which collide with
// macOS system shortcuts and with Option producing text. Rather than making
// the core configurable, the mapping table below emits the key the core
// already expects, so the physical shortcut can differ per platform (and,
// later, per user) with no change to src/.
#ifndef ARI_MACOS_KEYMAP_H
#define ARI_MACOS_KEYMAP_H

#include <cstdint>
#include <string_view>

#include <fcitx-utils/key.h>

#include "AriPreferences.h"

namespace ari {

enum Modifier : std::uint32_t {
    ModShift = 1u << 0,
    ModControl = 1u << 1,
    ModOption = 1u << 2,
    ModCommand = 1u << 3,
    ModCapsLock = 1u << 4,
};

struct KeyTranslation {
    bool valid = false;       // false: nothing Ari can act on
    bool passThrough = false; // valid, but the application should get it
    fcitx::Key key{0};
};

// The character the key produces with Shift applied and every other modifier
// ignored — the X11 keysym convention the core relies on, where Ctrl+Shift+comma
// arrives as '<' with the Shift bit set. NSEvent cannot supply this:
// -charactersIgnoringModifiers drops Shift too (Shift+2 reports "2", not "@"),
// and -characters mangles the value under Control/Option. Use
// shiftedCharacterForKeyCode() to obtain it.
// State the translation depends on beyond the key itself.
struct TranslationContext {
    // True while the candidate window is open. macOS input methods page the
    // candidate list with ←/→; Ari's core gives those keys to character
    // navigation instead, so the arrows are rewritten here rather than in the
    // core, and only while the list is actually open.
    bool candidateWindowOpen = false;
    ArrowStyle arrowStyle = ArrowStyle::MacOS;
};

KeyTranslation translateKey(std::uint16_t keyCode,
                            std::string_view shiftedCharacter,
                            std::uint32_t modifiers,
                            TranslationContext context = {});

// Resolve a virtual key code against the user's *keyboard layout* (not the
// active input method), applying only Shift and Caps Lock. Returns an empty
// string for keys that produce no character.
std::string shiftedCharacterForKeyCode(std::uint16_t keyCode, bool shift,
                                       bool capsLock = false);

} // namespace ari

#endif // ARI_MACOS_KEYMAP_H

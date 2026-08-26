// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
// Unit tests for the macOS key translation table (plan gaps G3 / G4).
#include <cstdio>
#include <string>

#import <Carbon/Carbon.h>

#include <fcitx-utils/keysym.h>

#include "KeyMap.h"

namespace {

int failures = 0;
int checks = 0;

void expectKey(const char *label, ari::KeyTranslation t, fcitx::KeySym sym,
               std::uint32_t states) {
    ++checks;
    if (!t.valid || t.passThrough || t.key.sym() != sym ||
        t.key.states().bits() != states) {
        ++failures;
        printf("FAIL %-46s valid=%d pass=%d sym=0x%x states=0x%x "
               "(want sym=0x%x states=0x%x)\n",
               label, t.valid, t.passThrough, t.key.sym(),
               t.key.states().bits(), sym, states);
    }
}

void expectPassThrough(const char *label, ari::KeyTranslation t) {
    ++checks;
    if (!t.passThrough) {
        ++failures;
        printf("FAIL %-46s expected pass-through\n", label);
    }
}

void expectInvalid(const char *label, ari::KeyTranslation t) {
    ++checks;
    if (t.valid) {
        ++failures;
        printf("FAIL %-46s expected no translation\n", label);
    }
}

constexpr std::uint32_t kCtrl = static_cast<std::uint32_t>(fcitx::KeyState::Ctrl);
constexpr std::uint32_t kAlt = static_cast<std::uint32_t>(fcitx::KeyState::Alt);
constexpr std::uint32_t kShift = static_cast<std::uint32_t>(fcitx::KeyState::Shift);

} // namespace

int main() {
    using ari::translateKey;

    // --- Layout resolution: the bug that shipped in M2 --------------------
    // translateKey is fed a character, so testing it alone proves nothing
    // about where that character comes from. NSEvent's
    // -charactersIgnoringModifiers drops Shift (Shift+1 reports "1"), which
    // silently disabled every shifted punctuation key. Check the real
    // resolver against the machine's keyboard layout.
    const std::string one = ari::shiftedCharacterForKeyCode(kVK_ANSI_1, false);
    if (one == "1") { // ASCII-compatible layout: assert the shifted forms
        ++checks;
        if (ari::shiftedCharacterForKeyCode(kVK_ANSI_1, true) != "!") {
            ++failures;
            printf("FAIL shift+1 resolves to '!' (got \"%s\")\n",
                   ari::shiftedCharacterForKeyCode(kVK_ANSI_1, true).c_str());
        }
        ++checks;
        if (ari::shiftedCharacterForKeyCode(kVK_ANSI_Comma, true) != "<") {
            ++failures;
            printf("FAIL shift+comma resolves to '<' (got \"%s\")\n",
                   ari::shiftedCharacterForKeyCode(kVK_ANSI_Comma, true).c_str());
        }
        ++checks;
        if (ari::shiftedCharacterForKeyCode(kVK_ANSI_Quote, true) != "\"") {
            ++failures;
            printf("FAIL shift+quote resolves to '\"'\n");
        }
        ++checks;
        if (ari::shiftedCharacterForKeyCode(kVK_ANSI_S, true) != "S") {
            ++failures;
            printf("FAIL shift+s resolves to 'S'\n");
        }
        // Caps Lock changes which character the layout produces. Ignoring it
        // made every letter lowercase while Caps Lock was engaged.
        ++checks;
        if (ari::shiftedCharacterForKeyCode(kVK_ANSI_S, false, true) != "S") {
            ++failures;
            printf("FAIL caps lock + s resolves to 'S' (got \"%s\")\n",
                   ari::shiftedCharacterForKeyCode(kVK_ANSI_S, false, true)
                       .c_str());
        }
        ++checks;
        if (ari::shiftedCharacterForKeyCode(kVK_ANSI_1, false, true) != "1") {
            ++failures;
            printf("FAIL caps lock does not shift digits\n");
        }
    } else {
        printf("SKIP layout resolution: non-ASCII keyboard layout (1 -> \"%s\")\n",
               one.c_str());
    }

    // --- Printable keys carry the character the key would produce ---------
    expectKey("plain s", translateKey(kVK_ANSI_S, "s", 0), FcitxKey_s, 0);
    expectKey("digit 3", translateKey(kVK_ANSI_3, "3", 0), 0x33, 0);
    expectKey("shifted comma is '<'",
              translateKey(kVK_ANSI_Comma, "<", ari::ModShift), FcitxKey_less,
              kShift);
    expectKey("ctrl+shift+comma keeps both",
              translateKey(kVK_ANSI_Comma, "<",
                           ari::ModShift | ari::ModControl),
              FcitxKey_less, kShift | kCtrl);
    expectKey("ctrl+z", translateKey(kVK_ANSI_Z, "z", ari::ModControl),
              FcitxKey_z, kCtrl);

    // --- Named keys come from the virtual key code ------------------------
    expectKey("return", translateKey(kVK_Return, "\r", 0), FcitxKey_Return, 0);
    expectKey("backspace", translateKey(kVK_Delete, "\x7f", 0),
              FcitxKey_BackSpace, 0);
    expectKey("forward delete", translateKey(kVK_ForwardDelete, "", 0),
              FcitxKey_Delete, 0);
    expectKey("escape", translateKey(kVK_Escape, "\x1b", 0), FcitxKey_Escape, 0);
    expectKey("space", translateKey(kVK_Space, " ", 0), FcitxKey_space, 0);
    expectKey("tab", translateKey(kVK_Tab, "\t", 0), FcitxKey_Tab, 0);
    expectKey("shift+tab becomes ISO_Left_Tab",
              translateKey(kVK_Tab, "\t", ari::ModShift), FcitxKey_ISO_Left_Tab,
              kShift);
    expectKey("left", translateKey(kVK_LeftArrow, "", 0), FcitxKey_Left, 0);
    expectKey("right", translateKey(kVK_RightArrow, "", 0), FcitxKey_Right, 0);
    expectKey("up", translateKey(kVK_UpArrow, "", 0), FcitxKey_Up, 0);
    expectKey("down", translateKey(kVK_DownArrow, "", 0), FcitxKey_Down, 0);
    expectKey("home", translateKey(kVK_Home, "", 0), FcitxKey_Home, 0);
    expectKey("end", translateKey(kVK_End, "", 0), FcitxKey_End, 0);
    expectKey("page up", translateKey(kVK_PageUp, "", 0), FcitxKey_Page_Up, 0);
    expectKey("page down", translateKey(kVK_PageDown, "", 0), FcitxKey_Page_Down,
              0);
    expectKey("ctrl+left navigation",
              translateKey(kVK_LeftArrow, "", ari::ModControl), FcitxKey_Left,
              kCtrl);

    // --- Numeric keypad stays literal ------------------------------------
    expectKey("keypad 1", translateKey(kVK_ANSI_Keypad1, "1", 0), FcitxKey_KP_1,
              0);
    expectKey("keypad 9", translateKey(kVK_ANSI_Keypad9, "9", 0), FcitxKey_KP_9,
              0);
    expectKey("keypad decimal", translateKey(kVK_ANSI_KeypadDecimal, ".", 0),
              FcitxKey_KP_Decimal, 0);
    expectKey("keypad enter", translateKey(kVK_ANSI_KeypadEnter, "\r", 0),
              FcitxKey_KP_Enter, 0);

    // --- Ari's macOS shortcuts translate to what the core expects ---------
    expectKey("ctrl+opt+E -> Ctrl+Space (中/英)",
              translateKey(kVK_ANSI_E, "e",
                           ari::ModControl | ari::ModOption),
              FcitxKey_space, kCtrl);
    expectKey("ctrl+opt+[ -> Alt+[ (「)",
              translateKey(kVK_ANSI_LeftBracket, "[",
                           ari::ModControl | ari::ModOption),
              FcitxKey_bracketleft, kAlt);
    expectKey("ctrl+opt+] -> Alt+] (」)",
              translateKey(kVK_ANSI_RightBracket, "]",
                           ari::ModControl | ari::ModOption),
              FcitxKey_bracketright, kAlt);
    // Adding another modifier must NOT trigger the shortcut: the application
    // keeps ⌘⌃⌥E and ⇧⌃⌥E.
    expectPassThrough("cmd+ctrl+opt+E stays with the app",
                      translateKey(kVK_ANSI_E, "e",
                                   ari::ModControl | ari::ModOption |
                                       ari::ModCommand));
    expectKey("shift+ctrl+opt+E is not the toggle",
              translateKey(kVK_ANSI_E, "E",
                           ari::ModControl | ari::ModOption | ari::ModShift),
              0x45 /* 'E' */, kShift | kCtrl | kAlt);

    // Caps Lock is a lock state, not part of the chord.
    expectKey("caps lock + ctrl+opt+E still toggles",
              translateKey(kVK_ANSI_E, "e",
                           ari::ModControl | ari::ModOption | ari::ModCapsLock),
              FcitxKey_space, kCtrl);
    // The core has no Caps Lock modifier; it must never be forwarded.
    expectKey("caps lock alone forwards no modifier",
              translateKey(kVK_ANSI_S, "S", ari::ModCapsLock), 0x53, 0);

    // --- Candidate-window arrows (macOS style) ---------------------------
    const ari::TranslationContext picking{.candidateWindowOpen = true,
                                          .arrowStyle = ari::ArrowStyle::MacOS};
    const ari::TranslationContext linux{.candidateWindowOpen = true,
                                        .arrowStyle = ari::ArrowStyle::Linux};
    const ari::TranslationContext typing{};

    expectKey("picking: left pages back",
              translateKey(kVK_LeftArrow, "", 0, picking), FcitxKey_Page_Up, 0);
    expectKey("picking: right pages forward",
              translateKey(kVK_RightArrow, "", 0, picking), FcitxKey_Page_Down, 0);
    expectKey("picking: opt+left walks characters",
              translateKey(kVK_LeftArrow, "", ari::ModOption, picking),
              FcitxKey_Left, 0);
    expectKey("picking: opt+right walks characters",
              translateKey(kVK_RightArrow, "", ari::ModOption, picking),
              FcitxKey_Right, 0);
    // Up/Down keep moving through the list, not pages.
    expectKey("picking: down is unchanged",
              translateKey(kVK_DownArrow, "", 0, picking), FcitxKey_Down, 0);
    // Outside the candidate window the arrows keep their caret meaning.
    expectKey("typing: left is still left",
              translateKey(kVK_LeftArrow, "", 0, typing), FcitxKey_Left, 0);
    // Ctrl+arrow is phrase navigation in the core and must survive.
    expectKey("picking: ctrl+left is untouched",
              translateKey(kVK_LeftArrow, "", ari::ModControl, picking),
              FcitxKey_Left, kCtrl);
    // The Linux style leaves everything alone.
    expectKey("linux style: left still walks characters",
              translateKey(kVK_LeftArrow, "", 0, linux), FcitxKey_Left, 0);

    // --- Which keys get their Chinese form -------------------------------
    for (const char *key : {"<", ">", "?", "!", ":", "'", "[", "]", "{", "}",
                            "(", ")", "~", "^"}) {
        ++checks;
        if (!ari::isChinesePunctuationKey(key)) {
            ++failures;
            printf("FAIL '%s' should take its Chinese form\n", key);
        }
    }
    // Symbols a programmer types inside Chinese text stay half-width.
    for (const char *key : {"@", "#", "$", "%", "&", "*", "+", "=", "_", "`",
                            "|"}) {
        ++checks;
        if (ari::isChinesePunctuationKey(key)) {
            ++failures;
            printf("FAIL '%s' should stay half-width\n", key);
        }
    }
    // Bopomofo finals must never be diverted to punctuation.
    for (const char *key : {",", ".", ";", "/", "-"}) {
        ++checks;
        if (ari::isChinesePunctuationKey(key)) {
            ++failures;
            printf("FAIL '%s' is a Bopomofo final, not punctuation\n", key);
        }
    }

    // --- Command belongs to the application ------------------------------
    expectPassThrough("cmd+c", translateKey(kVK_ANSI_C, "c", ari::ModCommand));
    expectPassThrough("cmd+q", translateKey(kVK_ANSI_Q, "q", ari::ModCommand));

    // --- Non-ASCII input is not ours -------------------------------------
    expectInvalid("dead-key output", translateKey(kVK_ANSI_E, "é", 0));
    expectInvalid("empty characters", translateKey(0x6e /* unmapped */, "", 0));

    printf("\n%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}

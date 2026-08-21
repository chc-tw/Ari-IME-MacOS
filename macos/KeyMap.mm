// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#include "KeyMap.h"

#include <fcitx-utils/keysym.h>

#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>

#include <string>

namespace ari {

namespace {

// The active keyboard layout, cached until the user switches layouts.
CFDataRef currentLayoutData() {
    static CFDataRef cached = nullptr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      [NSDistributedNotificationCenter.defaultCenter
          addObserverForName:(__bridge NSString *)
                             kTISNotifySelectedKeyboardInputSourceChanged
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification *) {
                    if (cached) {
                        CFRelease(cached);
                        cached = nullptr;
                    }
                  }];
    });
    if (!cached) {
        TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
        if (!source) {
            return nullptr;
        }
        CFDataRef data = static_cast<CFDataRef>(
            TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData));
        if (data) {
            cached = static_cast<CFDataRef>(CFRetain(data));
        }
        CFRelease(source);
    }
    return cached;
}

constexpr std::uint32_t kAriShortcutMods = ModControl | ModOption;

fcitx::KeyStates statesFor(std::uint32_t modifiers) {
    std::uint32_t bits = 0;
    if (modifiers & ModShift) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Shift);
    }
    if (modifiers & ModControl) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Ctrl);
    }
    if (modifiers & ModOption) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Alt);
    }
    if (modifiers & ModCommand) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Super);
    }
    // ModCapsLock is deliberately not forwarded: it changes which character the
    // layout produces, but the core has no Caps Lock modifier.
    return fcitx::KeyStates(bits);
}

// Keys that have no printable character; the virtual key code is the only
// reliable identity for them.
fcitx::KeySym symForKeyCode(std::uint16_t keyCode) {
    switch (keyCode) {
    case kVK_Return: return FcitxKey_Return;
    case kVK_Tab: return FcitxKey_Tab;
    case kVK_Space: return FcitxKey_space;
    case kVK_Delete: return FcitxKey_BackSpace;
    case kVK_ForwardDelete: return FcitxKey_Delete;
    case kVK_Escape: return FcitxKey_Escape;
    case kVK_Home: return FcitxKey_Home;
    case kVK_End: return FcitxKey_End;
    case kVK_PageUp: return FcitxKey_Page_Up;
    case kVK_PageDown: return FcitxKey_Page_Down;
    case kVK_LeftArrow: return FcitxKey_Left;
    case kVK_RightArrow: return FcitxKey_Right;
    case kVK_UpArrow: return FcitxKey_Up;
    case kVK_DownArrow: return FcitxKey_Down;
    case kVK_F1: return FcitxKey_F1;
    // The macOS numeric keypad always produces digits and symbols (there is no
    // NumLock-off navigation layer), which is exactly the literal behavior the
    // core assigns to the KP_* symbols.
    case kVK_ANSI_Keypad0: return FcitxKey_KP_0;
    case kVK_ANSI_Keypad1: return FcitxKey_KP_1;
    case kVK_ANSI_Keypad2: return FcitxKey_KP_2;
    case kVK_ANSI_Keypad3: return FcitxKey_KP_3;
    case kVK_ANSI_Keypad4: return FcitxKey_KP_4;
    case kVK_ANSI_Keypad5: return FcitxKey_KP_5;
    case kVK_ANSI_Keypad6: return FcitxKey_KP_6;
    case kVK_ANSI_Keypad7: return FcitxKey_KP_7;
    case kVK_ANSI_Keypad8: return FcitxKey_KP_8;
    case kVK_ANSI_Keypad9: return FcitxKey_KP_9;
    case kVK_ANSI_KeypadDecimal: return FcitxKey_KP_Decimal;
    case kVK_ANSI_KeypadDivide: return FcitxKey_KP_Divide;
    case kVK_ANSI_KeypadMultiply: return FcitxKey_KP_Multiply;
    case kVK_ANSI_KeypadMinus: return FcitxKey_KP_Subtract;
    case kVK_ANSI_KeypadPlus: return FcitxKey_KP_Add;
    case kVK_ANSI_KeypadEquals: return FcitxKey_KP_Equal;
    case kVK_ANSI_KeypadEnter: return FcitxKey_KP_Enter;
    default: return 0;
    }
}

// Ari's macOS shortcut defaults. Control+Option is a namespace macOS barely
// uses (only ⌃⌥Space, which we avoid) and it produces no text.
bool translateAriShortcut(std::uint16_t keyCode, std::uint32_t modifiers,
                          KeyTranslation &out) {
    // Caps Lock is a lock state, not a chord participant: it must not stop the
    // shortcut from matching.
    if ((modifiers & ~static_cast<std::uint32_t>(ModCapsLock)) !=
        kAriShortcutMods) {
        return false;
    }
    switch (keyCode) {
    case kVK_ANSI_E: // ⌃⌥E — 中/英 toggle (core expects Ctrl+Space)
        out = {true, false, fcitx::Key(FcitxKey_space, fcitx::KeyState::Ctrl)};
        return true;
    case kVK_ANSI_LeftBracket: // ⌃⌥[ — 「 (core expects Alt+[)
        out = {true, false,
               fcitx::Key(FcitxKey_bracketleft, fcitx::KeyState::Alt)};
        return true;
    case kVK_ANSI_RightBracket: // ⌃⌥] — 」 (core expects Alt+])
        out = {true, false,
               fcitx::Key(FcitxKey_bracketright, fcitx::KeyState::Alt)};
        return true;
    default:
        return false;
    }
}

} // namespace

std::string shiftedCharacterForKeyCode(std::uint16_t keyCode, bool shift,
                                       bool capsLock) {
    CFDataRef layoutData = currentLayoutData();
    if (!layoutData) {
        return {};
    }
    const auto *layout = reinterpret_cast<const UCKeyboardLayout *>(
        CFDataGetBytePtr(layoutData));

    UInt32 deadKeyState = 0;
    UniChar characters[8] = {};
    UniCharCount length = 0;
    // Caps Lock matters as much as Shift here: while it is engaged the layout
    // produces uppercase letters, and Ari must see the same characters the
    // application would have received.
    UInt32 modifierState = shift ? (shiftKey >> 8) : 0;
    if (capsLock) {
        modifierState |= (alphaLock >> 8);
    }
    const OSStatus status = UCKeyTranslate(
        layout, keyCode, kUCKeyActionDown, modifierState, LMGetKbdType(),
        kUCKeyTranslateNoDeadKeysMask, &deadKeyState, sizeof(characters) / sizeof(UniChar),
        &length, characters);
    if (status != noErr || length == 0) {
        return {};
    }
    NSString *text = [NSString stringWithCharacters:characters
                                             length:static_cast<NSUInteger>(length)];
    return text.UTF8String ?: "";
}

// Rewrite the arrows the way macOS users expect while the candidate window is
// open: ←/→ page the list, and ⌥←/⌥→ take over walking the pre-edit. Outside
// the candidate window the arrows keep their ordinary caret meaning.
bool translateCandidateArrow(std::uint16_t keyCode, std::uint32_t modifiers,
                             const TranslationContext &context,
                             KeyTranslation &out) {
    if (!context.candidateWindowOpen ||
        context.arrowStyle != ArrowStyle::MacOS) {
        return false;
    }
    const bool option = (modifiers & ModOption) != 0;
    if (modifiers & ~static_cast<std::uint32_t>(ModOption | ModCapsLock)) {
        return false; // any other modifier keeps its normal meaning
    }
    switch (keyCode) {
    case kVK_LeftArrow:
        out = {true, false, fcitx::Key(option ? FcitxKey_Left : FcitxKey_Page_Up)};
        return true;
    case kVK_RightArrow:
        out = {true, false,
               fcitx::Key(option ? FcitxKey_Right : FcitxKey_Page_Down)};
        return true;
    default:
        return false;
    }
}

KeyTranslation translateKey(std::uint16_t keyCode,
                            std::string_view shiftedCharacter,
                            std::uint32_t modifiers,
                            TranslationContext context) {
    KeyTranslation shortcut;
    if (translateAriShortcut(keyCode, modifiers, shortcut)) {
        return shortcut;
    }
    if (translateCandidateArrow(keyCode, modifiers, context, shortcut)) {
        return shortcut;
    }

    // Command belongs to the application (⌘C, ⌘Q, …). Ari reserves nothing
    // there, so hand the event straight back.
    if (modifiers & ModCommand) {
        return {true, true, fcitx::Key(0)};
    }

    const fcitx::KeyStates states = statesFor(modifiers);
    if (const fcitx::KeySym sym = symForKeyCode(keyCode); sym != 0) {
        // Shift+Tab is its own symbol in the core's navigation handling.
        if (sym == FcitxKey_Tab && (modifiers & ModShift)) {
            return {true, false, fcitx::Key(FcitxKey_ISO_Left_Tab, states)};
        }
        return {true, false, fcitx::Key(sym, states)};
    }

    if (shiftedCharacter.empty()) {
        return {};
    }
    const auto c = static_cast<unsigned char>(shiftedCharacter[0]);
    if (c < 0x20 || c > 0x7e) {
        return {}; // non-ASCII (dead keys, IME-produced text): not ours
    }
    return {true, false, fcitx::Key(static_cast<fcitx::KeySym>(c), states)};
}

} // namespace ari

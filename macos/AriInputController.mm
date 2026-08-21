// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import "AriInputController.h"

#import <Carbon/Carbon.h>

#include <string>
#include <vector>

#include <os/log.h>

#include <fcitx-utils/keysym.h>

#include "buffer.h"
#include "constants.h"
#include "layout.h"
#include "unicode.h"

#import "AriCandidateWindow.h"
#import "KeyMap.h"

namespace {

// Diagnostics for the input path. Read them with:
//   log stream --predicate 'subsystem == "io.github.chctw.inputmethod.AriIME"'
os_log_t ariLog() {
    static os_log_t log =
        os_log_create("io.github.chctw.inputmethod.AriIME", "input");
    return log;
}

NSString *toNSString(const std::string &text) {
    return [[NSString alloc] initWithBytes:text.data()
                                    length:static_cast<NSUInteger>(text.size())
                                  encoding:NSUTF8StringEncoding]
               ?: @"";
}

std::uint32_t modifiersFrom(NSEventModifierFlags flags) {
    std::uint32_t mods = 0;
    if (flags & NSEventModifierFlagShift) {
        mods |= ari::ModShift;
    }
    if (flags & NSEventModifierFlagControl) {
        mods |= ari::ModControl;
    }
    if (flags & NSEventModifierFlagOption) {
        mods |= ari::ModOption;
    }
    if (flags & NSEventModifierFlagCommand) {
        mods |= ari::ModCommand;
    }
    if (flags & NSEventModifierFlagCapsLock) {
        mods |= ari::ModCapsLock;
    }
    return mods;
}

// The marked-text selection range is measured in UTF-16 units, while Buffer
// counts grapheme clusters. Convert through the UTF-8 byte offset.
NSUInteger utf16OffsetForGrapheme(const std::string &text, int grapheme) {
    if (grapheme < 0) {
        return toNSString(text).length;
    }
    const std::size_t bytes = inputer::unicode::graphemeOffset(text, grapheme);
    return toNSString(text.substr(0, bytes)).length;
}

// One shared candidate panel: only one input context composes at a time.
AriCandidateWindow *sharedCandidateWindow() {
    static AriCandidateWindow *window = [[AriCandidateWindow alloc] init];
    return window;
}

} // namespace

@implementation AriInputController {
    Buffer _buffer;
    // Set once we have told the user the 注音 engine failed to load.
    BOOL _engineErrorNotified;
}

// IMK only delivers the event types the controller asks for. Without this the
// controller can be created and selected while never seeing a keystroke.
- (NSUInteger)recognizedEvents:(id)sender {
    (void)sender;
    return NSEventMaskKeyDown;
}

- (void)activateServer:(id)sender {
    os_log_info(ariLog(), "activateServer client=%{public}@ engineReady=%d",
                [sender class], _buffer.engineReady());
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
    if (event.type != NSEventTypeKeyDown) {
        return NO;
    }
    os_log_debug(ariLog(), "keyDown code=%d mods=0x%lx", (int)event.keyCode,
                 (unsigned long)event.modifierFlags);

    // macOS reports secure input globally rather than per field, so Ari takes
    // the conservative reading: while any application has secure input on,
    // nothing is learned.
    _buffer.setLearningAllowed(!IsSecureEventInputEnabled());

    // NSEvent cannot report "the character with only Shift applied", so resolve
    // it against the keyboard layout instead. -charactersIgnoringModifiers
    // drops Shift as well (Shift+1 reports "1"), which silently turned every
    // shifted punctuation key into its unshifted form.
    const std::uint32_t modifiers = modifiersFrom(event.modifierFlags);
    const std::string character = ari::shiftedCharacterForKeyCode(
        event.keyCode, (modifiers & ari::ModShift) != 0,
        (modifiers & ari::ModCapsLock) != 0);
    const ari::KeyTranslation translated =
        ari::translateKey(event.keyCode, character, modifiers);
    if (!translated.valid || translated.passThrough) {
        return NO;
    }

    if (!_buffer.engineReady() && !_engineErrorNotified) {
        _engineErrorNotified = YES;
        [self showTransient:@"注音引擎載入失敗，暫以英文輸入" client:sender];
    }

    const KeyResult result = _buffer.handleKey(translated.key);
    [self applyResult:result client:sender];
    os_log_debug(ariLog(), "char=%{public}s handled=%d preedit=%{public}s",
                 character.c_str(), result.handled,
                 _buffer.preeditText().c_str());
    return result.handled ? YES : NO;
}

- (void)applyResult:(const KeyResult &)result client:(id)sender {
    if (result.hasCommit && !result.commitText.empty()) {
        [sender insertText:toNSString(result.commitText)
          replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    if (result.notifyMode) {
        [self showTransient:(_buffer.isForcedEnglish() ? @"英 English" : @"中 中文")
                     client:sender];
    }
    if (!result.notification.empty()) {
        [self showTransient:toNSString(result.notification) client:sender];
    }
    if (result.updateUI || result.hasCommit) {
        [self updateUIForClient:sender];
    }
}

- (void)updateUIForClient:(id)sender {
    const std::string preedit = _buffer.preeditText();
    NSString *preeditString = toNSString(preedit);

    if (preedit.empty()) {
        [sender setMarkedText:@""
               selectionRange:NSMakeRange(0, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
        [sharedCandidateWindow() hide];
        return;
    }

    NSMutableAttributedString *marked =
        [[NSMutableAttributedString alloc] initWithString:preeditString];
    [marked addAttribute:NSUnderlineStyleAttributeName
                   value:@(NSUnderlineStyleSingle)
                   range:NSMakeRange(0, preeditString.length)];
    const NSUInteger caret =
        utf16OffsetForGrapheme(preedit, _buffer.caretChar());
    [sender setMarkedText:marked
           selectionRange:NSMakeRange(caret, 0)
         replacementRange:NSMakeRange(NSNotFound, 0)];

    [self showCandidatesForClient:sender];
}

- (void)showCandidatesForClient:(id)sender {
    const std::vector<std::string> candidates = _buffer.candidates();
    if (candidates.empty()) {
        [sharedCandidateWindow() hide];
        return;
    }

    NSMutableArray<NSString *> *items =
        [NSMutableArray arrayWithCapacity:candidates.size()];
    for (const auto &candidate : candidates) {
        [items addObject:toNSString(candidate)];
    }

    NSString *auxDown = @"";
    const int pages = _buffer.candidatePageCount();
    if (pages > 1) {
        auxDown = [NSString stringWithFormat:@"候選 %d/%d",
                                             _buffer.candidatePage(), pages];
    }

    [sharedCandidateWindow() showCandidates:items
                                  highlight:_buffer.highlight()
                                      auxUp:@""
                                    auxDown:auxDown
                                     atRect:[self caretRectForClient:sender]];
}

- (NSRect)caretRectForClient:(id)sender {
    NSRect rect = NSMakeRect(0, 0, 0, 0);
    if ([sender respondsToSelector:@selector(attributesForCharacterIndex:lineHeightRectangle:)]) {
        [sender attributesForCharacterIndex:0 lineHeightRectangle:&rect];
    }
    if (NSIsEmptyRect(rect)) {
        rect = NSMakeRect(NSMidX(NSScreen.mainScreen.frame),
                          NSMidY(NSScreen.mainScreen.frame), 1, 16);
    }
    return rect;
}

// M2 placeholder for the transient 中/英 and action hints. It reuses the
// candidate panel; a dedicated HUD arrives with the rest of the UI work.
- (void)showTransient:(NSString *)message client:(id)sender {
    [sharedCandidateWindow() showCandidates:@[]
                                  highlight:-1
                                      auxUp:message
                                    auxDown:@""
                                     atRect:[self caretRectForClient:sender]];
    __weak AriCandidateWindow *window = sharedCandidateWindow();
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [window hide];
        });
}

// macOS reports the Caps Lock language switch (and the ABC entry in the input
// menu) by setting the text service input mode. Ari has no separate Roman mode;
// it maps the request onto the forced-English state the core already owns.
// Toggling goes through the same Ctrl+Space the core hard-codes, so no core
// change is needed to gain a second way of switching.
- (void)setValue:(id)value forTag:(long)tag client:(id)sender {
    os_log_info(ariLog(), "setValue tag=%ld value=%{public}@", tag, value);
    if (tag == kTextServiceInputModePropertyTag &&
        [value isKindOfClass:NSString.class]) {
        NSString *mode = value;
        const BOOL wantEnglish =
            [mode hasSuffix:@".Roman"] || [mode containsString:@"ASCII"];
        if (wantEnglish != _buffer.isForcedEnglish()) {
            const KeyResult result = _buffer.handleKey(
                fcitx::Key(FcitxKey_space, fcitx::KeyState::Ctrl));
            [self applyResult:result client:sender];
        }
        return;
    }
    [super setValue:value forTag:tag client:sender];
}

- (void)commitComposition:(id)sender {
    const std::string preedit = _buffer.preeditText();
    if (!preedit.empty()) {
        [sender insertText:toNSString(preedit)
          replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    _buffer.reset();
    [sender setMarkedText:@""
           selectionRange:NSMakeRange(0, 0)
         replacementRange:NSMakeRange(NSNotFound, 0)];
    [sharedCandidateWindow() hide];
}

- (void)deactivateServer:(id)sender {
    [self commitComposition:sender];
}

@end

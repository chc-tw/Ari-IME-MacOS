// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import "AriInputController.h"

#import <Carbon/Carbon.h>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#include <os/log.h>

#include <fcitx-utils/keysym.h>

#include "buffer.h"
#include "constants.h"
#include "layout.h"
#include "unicode.h"

#import "AriCandidateWindow.h"
#import "AriHUD.h"
#import "AriBopomofo.h"
#import "AriPreferences.h"
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

// The auxiliary line Fcitx5 draws above the candidates while re-selecting:
// a window of nearby characters with the focused one (or the caret) marked.
// The client renders the inline pre-edit however it likes, so this is the one
// place the user can reliably see WHICH character is being edited.
NSString *editingPreview(const std::string &text, int position, bool picking) {
    constexpr int kContextChars = 10;
    const std::vector<std::string> chars = inputer::unicode::splitGraphemes(text);
    const int total = static_cast<int>(chars.size());
    position = std::clamp(position, 0, total);
    const int start = std::max(0, position - kContextChars);
    const int end = std::min(total, position + kContextChars + (picking ? 1 : 0));

    std::string out;
    if (start > 0) {
        out += "…";
    }
    for (int i = start; i < end; ++i) {
        if (!picking && i == position) {
            out += "|";
        }
        if (picking && i == position) {
            out += "[" + chars[i] + "]";
        } else {
            out += chars[i];
        }
    }
    if (!picking && position == end) {
        out += "|";
    }
    if (end < total) {
        out += "…";
    }
    return toNSString(out);
}

std::string statusText(const Buffer &buffer) {
    std::string out = buffer.isForcedEnglish() ? "英" : "中";
    out += " · ";
    out += inputer::keyboardLayoutName(buffer.keyboardLayout());
    out += " · ";
    out += buffer.isFullWidthPunct() ? "全形標點" : "半形標點";
    return out;
}

NSString *joinAuxParts(NSArray<NSString *> *parts) {
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [kept addObject:part];
        }
    }
    return [kept componentsJoinedByString:@" · "];
}

// One shared candidate panel: only one input context composes at a time.
AriCandidateWindow *sharedCandidateWindow() {
    static AriCandidateWindow *window = [[AriCandidateWindow alloc] init];
    return window;
}

} // namespace

// The state machine, exposed to this file only.
@interface AriInputController ()
@property(nonatomic, readonly) Buffer &buffer;
@end

@implementation AriInputController {
    // Held by pointer so a forget can destroy the state machine (and with it
    // the libchewing context, which is what actually writes the personal
    // dictionary) and start a fresh one.
    std::unique_ptr<Buffer> _buffer;
    // Reconversion: the client's original selection, kept so Escape or a focus
    // change can put it back instead of losing the user's text.
    BOOL _reconversionActive;
    NSString *_reconversionText;
    NSRange _reconversionRange;
    // Applied to the next setMarkedText so the marked composition replaces the
    // selected range rather than being inserted next to it.
    NSRange _pendingReplacement;
    // libchewing only writes the personal dictionary when the context is
    // destroyed, and exposes no flush API. A forget therefore has to wait for
    // the composition to end before it can be made durable.
    BOOL _forgetPendingFlush;
    // The last caret rectangle a client actually reported, see
    // -caretRectForClient:.
    NSRect _lastCaretRect;
    // Mirrors the Fcitx5 addon's ShowStatusLine option; off by default, as
    // there.
    BOOL _showStatusLine;
    BOOL _showBopomofo;
    // Set once we have told the user the 注音 engine failed to load.
    BOOL _engineErrorNotified;
}

// IMK only delivers the event types the controller asks for. Without this the
// controller can be created and selected while never seeing a keystroke.
- (NSUInteger)recognizedEvents:(id)sender {
    (void)sender;
    return NSEventMaskKeyDown;
}

- (instancetype)initWithServer:(IMKServer *)server
                      delegate:(id)delegate
                        client:(id)client {
    self = [super initWithServer:server delegate:delegate client:client];
    if (self) {
        _pendingReplacement = NSMakeRange(NSNotFound, 0);
        _reconversionRange = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

// Created on demand so the controller works regardless of which initializer
// InputMethodKit uses.
- (Buffer &)buffer {
    if (!_buffer) {
        _buffer = std::make_unique<Buffer>();
    }
    return *_buffer;
}

- (void)activateServer:(id)sender {
    os_log_info(ariLog(), "activateServer client=%{public}@ engineReady=%d",
                [sender class], self.buffer.engineReady());
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
    if (event.type != NSEventTypeKeyDown) {
        return NO;
    }
    os_log_debug(ariLog(), "keyDown code=%d mods=0x%lx", (int)event.keyCode,
                 (unsigned long)event.modifierFlags);

    // Applying the preferences on every keystroke is cheap and idempotent, and
    // means a change takes effect immediately in every context — the same
    // approach the Fcitx5 frontend takes with its addon config.
    const ari::Preferences preferences = ari::currentPreferences();
    _showStatusLine = preferences.showStatusLine;
    _showBopomofo = preferences.showBopomofo;
    if (self.buffer.setKeyboardLayout(preferences.layout)) {
        [self showTransient:toNSString(std::string("鍵盤 ") +
                                       inputer::keyboardLayoutName(preferences.layout))
                     client:sender];
    }
    self.buffer.setChinesePunctuationShortcut(preferences.punctuationShortcut);
    self.buffer.setSpaceCandidateMode(preferences.spaceCandidateMode);

    // macOS reports secure input globally rather than per field, so Ari takes
    // the conservative reading: while any application has secure input on,
    // nothing is learned.
    self.buffer.setLearningAllowed(preferences.autoLearn &&
                                   !IsSecureEventInputEnabled());

    // NSEvent cannot report "the character with only Shift applied", so resolve
    // it against the keyboard layout instead. -charactersIgnoringModifiers
    // drops Shift as well (Shift+1 reports "1"), which silently turned every
    // shifted punctuation key into its unshifted form.
    const std::uint32_t modifiers = modifiersFrom(event.modifierFlags);
    // ⌘V pastes into the pre-edit, but only while composing. Fcitx5 always
    // routes Ctrl+V through the buffer; on macOS that would break ⌘V for every
    // application and every non-text flavour on the pasteboard, so Ari only
    // claims it when it actually has a composition to paste into.
    if ((modifiers & ari::ModCommand) && event.keyCode == kVK_ANSI_V &&
        !(modifiers & (ari::ModControl | ari::ModOption)) &&
        !self.buffer.preeditText().empty() && [self pasteIntoBuffer:sender]) {
        return YES;
    }

    const std::string character = ari::shiftedCharacterForKeyCode(
        event.keyCode, (modifiers & ari::ModShift) != 0,
        (modifiers & ari::ModCapsLock) != 0);
    // The core has one switch for "full-width punctuation", which covers both
    // Chinese punctuation (，。「」？！) and full-width forms of the symbols a
    // programmer types inside Chinese text (＠＃％＆). The system Bopomofo input
    // method separates the two, and so does Ari on macOS: decide per key which
    // of the two this character belongs to and ask the core for the right one.
    // Everything the core already knows how to produce is reused; only the
    // choice of when to ask for it lives here.
    self.buffer.setFullWidthPunct(
        preferences.punctuationStyle == ari::PunctuationStyle::Chinese &&
        !self.buffer.isForcedEnglish() &&
        ari::isChinesePunctuationKey(character));

    const ari::KeyTranslation translated = ari::translateKey(
        event.keyCode, character, modifiers,
        {.candidateWindowOpen = self.buffer.isPicking(),
         .arrowStyle = preferences.arrowStyle});
    if (!translated.valid || translated.passThrough) {
        return NO;
    }

    if (!self.buffer.engineReady() && !_engineErrorNotified) {
        _engineErrorNotified = YES;
        [self showTransient:@"注音引擎載入失敗，暫以英文輸入" client:sender];
    }

    // ⌃⌥R reopens a short, already-committed Chinese selection for ordinary
    // candidate editing. When the client cannot offer a usable selection the
    // shortcut is left untouched for the application.
    if (event.keyCode == kVK_ANSI_R &&
        (modifiers & ~static_cast<std::uint32_t>(ari::ModCapsLock)) ==
            (ari::ModControl | ari::ModOption)) {
        if ([self beginReconversionWithClient:sender]) {
            return YES;
        }
        // Reconversion declined — most often because a composition is already
        // in flight. Swallow the shortcut anyway rather than letting the
        // application see a stray key while marked text is on screen: many
        // clients drop the marked text when that happens, which looks like the
        // user's text vanishing.
        if (!self.buffer.preeditText().empty()) {
            return YES;
        }
    }

    // A bare Space with nothing composed belongs to the application. The core
    // parks it in the pre-edit (everything is held until Enter), which is
    // harmless in a text field but wrong everywhere else on macOS: Space is
    // Quick Look in Finder, play/pause in media apps, and activates the
    // focused control. In a text field the application inserts exactly the
    // same space, so nothing is lost by declining it.
    if (translated.key.sym() == FcitxKey_space &&
        (modifiers & ~static_cast<std::uint32_t>(ari::ModCapsLock)) == 0 &&
        self.buffer.preeditText().empty()) {
        return NO;
    }

    const KeyResult result = self.buffer.handleKey(translated.key);

    // Escape during reconversion must give the original text back.
    if (_reconversionActive && translated.key.sym() == FcitxKey_Escape &&
        result.handled) {
        [self cancelReconversionWithClient:sender];
        return YES;
    }

    [self applyResult:result client:sender];
    if (_reconversionActive && result.hasCommit) {
        _reconversionActive = NO;
        _reconversionText = nil;
    }
    if (!result.notification.empty() &&
        result.notification.rfind("已忘記", 0) == 0) {
        _forgetPendingFlush = YES;
    }
    os_log_debug(ariLog(), "char=%{public}s handled=%d preedit=%{public}s",
                 character.c_str(), result.handled,
                 self.buffer.preeditText().c_str());
    return result.handled ? YES : NO;
}

- (void)applyResult:(const KeyResult &)result client:(id)sender {
    if (result.hasCommit && !result.commitText.empty()) {
        [sender insertText:toNSString(result.commitText)
          replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    if (result.notifyMode) {
        [self showTransient:(self.buffer.isForcedEnglish() ? @"英 English" : @"中 中文")
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
    const std::string preedit = self.buffer.preeditText();
    NSString *preeditString = toNSString(preedit);

    const NSRange replacement = _pendingReplacement;
    _pendingReplacement = NSMakeRange(NSNotFound, 0);

    if (preedit.empty()) {
        [sender setMarkedText:@""
               selectionRange:NSMakeRange(0, 0)
             replacementRange:replacement];
        [sharedCandidateWindow() hide];
        return;
    }

    NSMutableAttributedString *marked =
        [[NSMutableAttributedString alloc] initWithString:preeditString];
    [marked addAttribute:NSUnderlineStyleAttributeName
                   value:@(NSUnderlineStyleSingle)
                   range:NSMakeRange(0, preeditString.length)];
    const NSUInteger caret =
        utf16OffsetForGrapheme(preedit, self.buffer.caretChar());
    [sender setMarkedText:marked
           selectionRange:NSMakeRange(caret, 0)
         replacementRange:replacement];

    [self showPanelForClient:sender preedit:preedit];
}

- (void)showPanelForClient:(id)sender preedit:(const std::string &)preedit {
    const std::vector<std::string> candidates = self.buffer.candidates();
    const bool editing = self.buffer.isEditing();
    // The reading of the syllable in progress. The pre-edit shows the raw keys,
    // because they may still turn out to be English; this shows what Ari is
    // currently making of them.
    NSString *reading = @"";
    if (_showBopomofo && !editing) {
        reading = toNSString(ari::readingForKeys(self.buffer.pendingSyllable()));
    }
    if (candidates.empty() && !editing) {
        if (reading.length == 0) {
            [sharedCandidateWindow() hide];
            return;
        }
        [sharedCandidateWindow() showCandidates:@[]
                                      highlight:-1
                                          auxUp:reading
                                        auxDown:@""
                                         atRect:[self caretRectForClient:sender]];
        return;
    }

    NSMutableArray<NSString *> *items =
        [NSMutableArray arrayWithCapacity:candidates.size()];
    for (const auto &candidate : candidates) {
        [items addObject:toNSString(candidate)];
    }

    // Above the list: which character is being edited.
    NSString *auxUp = @"";
    if (editing) {
        const bool picking = self.buffer.isPicking();
        auxUp = editingPreview(
            preedit, picking ? self.buffer.selectionChar() : self.buffer.caretChar(),
            picking);
    }

    // Below it: candidate page, cursor position, and the optional status line.
    NSMutableArray<NSString *> *auxParts = [NSMutableArray array];
    const int pages = self.buffer.candidatePageCount();
    if (pages > 1) {
        [auxParts addObject:[NSString stringWithFormat:@"候選 %d/%d",
                                                       self.buffer.candidatePage(),
                                                       pages]];
    }
    if (editing) {
        const int total = static_cast<int>(
            inputer::unicode::splitGraphemes(preedit).size());
        if (self.buffer.isPicking()) {
            [auxParts addObject:[NSString stringWithFormat:@"選字 %d/%d",
                                                           self.buffer.selectionChar() + 1,
                                                           total]];
        } else {
            [auxParts addObject:[NSString stringWithFormat:@"游標 %d/%d",
                                                           std::max(self.buffer.caretChar(), 0),
                                                           total]];
        }
    }
    if (_showStatusLine) {
        [auxParts addObject:toNSString(statusText(self.buffer))];
    }

    [sharedCandidateWindow() showCandidates:items
                                  highlight:self.buffer.highlight()
                                      auxUp:auxUp
                                    auxDown:joinAuxParts(auxParts)
                                     atRect:[self caretRectForClient:sender]];
}

- (NSRect)caretRectForClient:(id)sender {
    NSRect rect = NSZeroRect;
    if ([sender respondsToSelector:@selector(attributesForCharacterIndex:
                                                    lineHeightRectangle:)]) {
        // The index is an offset into the marked text, so index 0 pins the
        // panel to where the composition started and leaves it there while the
        // text grows. Ask about the caret instead, and fall back to the start
        // for clients that only answer for index 0.
        const std::string preedit = self.buffer.preeditText();
        const NSUInteger caret =
            utf16OffsetForGrapheme(preedit, self.buffer.caretChar());
        if (caret > 0) {
            [sender attributesForCharacterIndex:caret lineHeightRectangle:&rect];
        }
        if (NSIsEmptyRect(rect)) {
            [sender attributesForCharacterIndex:0 lineHeightRectangle:&rect];
        }
    }
    if (!NSIsEmptyRect(rect)) {
        _lastCaretRect = rect;
        return rect;
    }
    // Clients intermittently report an empty rectangle (TextEdit does, between
    // one keystroke and the next). Reusing the last known caret keeps the panel
    // where the user is typing instead of throwing it to the middle of the
    // screen.
    if (!NSIsEmptyRect(_lastCaretRect)) {
        return _lastCaretRect;
    }
    return NSMakeRect(NSMidX(NSScreen.mainScreen.frame),
                      NSMidY(NSScreen.mainScreen.frame), 1, 16);
}

// Reconversion needs a selection the client can both read and replace. Any
// doubt (secure input, an active composition, no selection, text Ari cannot
// find readings for) means declining without touching the document.
- (BOOL)beginReconversionWithClient:(id)sender {
    if (_reconversionActive || IsSecureEventInputEnabled() ||
        self.buffer.isForcedEnglish() || !self.buffer.preeditText().empty()) {
        return NO;
    }
    if (![sender respondsToSelector:@selector(selectedRange)] ||
        ![sender respondsToSelector:@selector(attributedSubstringFromRange:)]) {
        return NO;
    }
    const NSRange selection = [sender selectedRange];
    os_log_info(ariLog(), "reconversion: client=%{public}@ selection=%lu,%lu",
                [sender class], (unsigned long)selection.location,
                (unsigned long)selection.length);
    if (selection.length == 0 || selection.location == NSNotFound) {
        return NO;
    }
    NSAttributedString *selected =
        [sender attributedSubstringFromRange:selection];
    NSString *text = selected.string;
    os_log_info(ariLog(), "reconversion: selected=%{public}@", text);
    if (text.length == 0) {
        return NO;
    }

    const KeyResult result = self.buffer.beginReconversion(text.UTF8String ?: "");
    os_log_info(ariLog(), "reconversion: handled=%d preedit=%{public}s",
                result.handled, self.buffer.preeditText().c_str());
    if (!result.handled) {
        return NO; // no reading for some grapheme: leave the document alone
    }

    _reconversionActive = YES;
    _reconversionText = text;
    _reconversionRange = selection;
    // The composition replaces the selection in one step; there is no separate
    // "delete surrounding text" call on macOS.
    _pendingReplacement = selection;
    [self updateUIForClient:sender];
    return YES;
}

- (void)cancelReconversionWithClient:(id)sender {
    NSString *original = _reconversionText;
    _reconversionActive = NO;
    _reconversionText = nil;
    self.buffer.reset();
    [sender setMarkedText:@""
           selectionRange:NSMakeRange(0, 0)
         replacementRange:NSMakeRange(NSNotFound, 0)];
    if (original.length > 0) {
        [sender insertText:original
          replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    [sharedCandidateWindow() hide];
}

// Destroy and recreate the state machine so libchewing writes the personal
// dictionary. Only safe with no composition in flight, so it runs when the
// composition ends.
- (void)flushForgetIfPending {
    if (!_forgetPendingFlush) {
        return;
    }
    _forgetPendingFlush = NO;
    const bool forcedEnglish = self.buffer.isForcedEnglish();
    _buffer.reset(); // destroying the context is what flushes the dictionary
    if (forcedEnglish != self.buffer.isForcedEnglish()) {
        self.buffer.handleKey(fcitx::Key(FcitxKey_space, fcitx::KeyState::Ctrl));
    }
}

// Returns NO when the pasteboard holds nothing Ari can insert, so the
// application still receives the shortcut.
- (BOOL)pasteIntoBuffer:(id)sender {
    NSString *text =
        [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (text.length == 0) {
        return NO;
    }
    self.buffer.pasteAtCaret(text.UTF8String ?: "");
    [self updateUIForClient:sender];
    return YES;
}

- (void)showTransient:(NSString *)message client:(id)sender {
    [AriHUD.shared show:message atRect:[self caretRectForClient:sender]];
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
        if (wantEnglish != self.buffer.isForcedEnglish()) {
            const KeyResult result = self.buffer.handleKey(
                fcitx::Key(FcitxKey_space, fcitx::KeyState::Ctrl));
            [self applyResult:result client:sender];
        }
        return;
    }
    [super setValue:value forTag:tag client:sender];
}

- (void)commitComposition:(id)sender {
    if (_reconversionActive) {
        // Focus left mid-reconversion: hand back exactly what was selected.
        [self cancelReconversionWithClient:sender];
        [self flushForgetIfPending];
        return;
    }
    const std::string preedit = self.buffer.preeditText();
    if (!preedit.empty()) {
        [sender insertText:toNSString(preedit)
          replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    self.buffer.reset();
    [sender setMarkedText:@""
           selectionRange:NSMakeRange(0, 0)
         replacementRange:NSMakeRange(NSNotFound, 0)];
    [sharedCandidateWindow() hide];
    [self flushForgetIfPending];
}

- (void)deactivateServer:(id)sender {
    [self commitComposition:sender];
}

@end

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Drives AriInputController through synthetic key events against a fake IMK
// client, so the frontend contract (marked text, commit, pass-through) is
// verified without touching the user's real input source. Plan gap G5.
#include <cstdio>
#include <string>
#include <unistd.h>

#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>

#import "AriInputController.h"
#import "KeyMap.h"

#include <map>

static int failures = 0;
static int checks = 0;

static void checkEq(NSString *actual, NSString *expected, const char *label) {
    ++checks;
    if (![actual isEqualToString:expected]) {
        ++failures;
        printf("FAIL %-44s got=\"%s\" want=\"%s\"\n", label,
               actual.UTF8String ?: "(nil)", expected.UTF8String);
    }
}

static void check(BOOL condition, const char *label) {
    ++checks;
    if (!condition) {
        ++failures;
        printf("FAIL %s\n", label);
    }
}

// Minimal stand-in for the text input client an application provides.
@interface FakeClient : NSObject
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic, copy) NSString *committed;
@property(nonatomic) NSRange markedSelection;
@property(nonatomic) BOOL markedIsUnderlined;
// Enough of a document model to exercise reconversion: the text already in the
// client, what is selected, and the replacement range Ari asks for.
@property(nonatomic, copy) NSString *documentText;
@property(nonatomic) NSRange selectedRange;
@property(nonatomic) NSRange lastMarkedReplacement;
@end

@implementation FakeClient

- (instancetype)init {
    self = [super init];
    _markedText = @"";
    _committed = @"";
    _documentText = @"";
    _selectedRange = NSMakeRange(NSNotFound, 0);
    _lastMarkedReplacement = NSMakeRange(NSNotFound, 0);
    return self;
}

- (void)insertText:(id)string replacementRange:(NSRange)range {
    (void)range;
    NSString *text = [string isKindOfClass:NSAttributedString.class]
                         ? [(NSAttributedString *)string string]
                         : (NSString *)string;
    _committed = [_committed stringByAppendingString:text];
    _markedText = @"";
}

- (NSAttributedString *)attributedSubstringFromRange:(NSRange)range {
    if (NSMaxRange(range) > _documentText.length) {
        return nil;
    }
    return [[NSAttributedString alloc]
        initWithString:[_documentText substringWithRange:range]];
}

- (void)setMarkedText:(id)string
       selectionRange:(NSRange)selectionRange
     replacementRange:(NSRange)replacementRange {
    _lastMarkedReplacement = replacementRange;
    _markedIsUnderlined = NO;
    if ([string isKindOfClass:NSAttributedString.class]) {
        NSAttributedString *attributed = string;
        _markedText = attributed.string;
        if (attributed.length > 0) {
            _markedIsUnderlined =
                [attributed attribute:NSUnderlineStyleAttributeName
                              atIndex:0
                       effectiveRange:NULL] != nil;
        }
    } else {
        _markedText = string;
    }
    _markedSelection = selectionRange;
}

- (void)attributesForCharacterIndex:(NSUInteger)index
                lineHeightRectangle:(NSRect *)rect {
    (void)index;
    *rect = NSMakeRect(100, 400, 1, 16);
}

@end

namespace {

// Map each ASCII character back to the (virtual key code, shift) pair that
// produces it on the machine's keyboard layout. Synthetic events must carry a
// real key code: the controller resolves characters from the layout, exactly
// as it does for physical keystrokes.
struct KeyStroke {
    std::uint16_t code = 0;
    bool shift = false;
};

const std::map<std::string, KeyStroke> &asciiKeyStrokes() {
    static const std::map<std::string, KeyStroke> table = [] {
        std::map<std::string, KeyStroke> map;
        for (std::uint16_t code = 0; code < 128; ++code) {
            for (bool shift : {false, true}) {
                const std::string text =
                    ari::shiftedCharacterForKeyCode(code, shift);
                if (text.size() == 1 && text[0] >= 0x20 && text[0] < 0x7f) {
                    map.emplace(text, KeyStroke{code, shift});
                }
            }
        }
        return map;
    }();
    return table;
}

NSEvent *keyEvent(std::uint16_t keyCode, NSString *characters,
                  NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                            location:NSZeroPoint
                       modifierFlags:flags
                           timestamp:0
                        windowNumber:0
                             context:nil
                          characters:characters
         charactersIgnoringModifiers:characters
                           isARepeat:NO
                             keyCode:keyCode];
}

struct Session {
    AriInputController *controller;
    FakeClient *client;

    Session() {
        controller = [[AriInputController alloc] initWithServer:nil
                                                       delegate:nil
                                                         client:nil];
        client = [[FakeClient alloc] init];
    }

    BOOL send(std::uint16_t keyCode, NSString *chars,
              NSEventModifierFlags flags = 0) {
        return [controller handleEvent:keyEvent(keyCode, chars, flags)
                                client:client];
    }

    // Type ASCII through the same path a keyboard would: real key codes, and
    // Shift where the layout requires it.
    void type(NSString *text) {
        for (NSUInteger i = 0; i < text.length; ++i) {
            NSString *ch = [text substringWithRange:NSMakeRange(i, 1)];
            const auto it = asciiKeyStrokes().find(ch.UTF8String);
            if (it == asciiKeyStrokes().end()) {
                printf("FAIL no key produces \"%s\" on this layout\n",
                       ch.UTF8String);
                ++failures;
                ++checks;
                continue;
            }
            send(it->second.code, ch,
                 it->second.shift ? NSEventModifierFlagShift : 0);
        }
    }
};

} // namespace

int main() {
    @autoreleasepool {
        // Sandbox the personal dictionary before any Buffer is constructed:
        // these tests must never read or write the real
        // ~/Library/Application Support/AriIME.
        NSString *sandbox = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"ari-controller-test-%d", getpid()]];
        setenv("ARI_IME_USER_DATA_DIR", sandbox.UTF8String, 1);
        setenv("CHEWING_USER_PATH", sandbox.UTF8String, 1);
        setenv("ARI_IME_DISABLE_AUTOLEARN", "1", 1);

        [NSApplication sharedApplication];

        { // Mixed Chinese/English composition is held until Enter.
            Session s;
            s.type(@"aceru/6aj4");
            checkEq(s.client.markedText, @"acer螢幕", "mixed preedit is marked");
            checkEq(s.client.committed, @"", "nothing is committed before Enter");
            check(s.client.markedIsUnderlined, "marked text is underlined");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"acer螢幕", "Enter commits the preedit");
            checkEq(s.client.markedText, @"", "marked text clears after commit");
        }

        { // Plain English stays literal.
            Session s;
            s.type(@"README.md");
            checkEq(s.client.markedText, @"README.md", "literal English preedit");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"README.md", "literal English commits");
        }

        { // A tone completes the syllable; Backspace edits the preedit.
            Session s;
            s.type(@"su3");
            checkEq(s.client.markedText, @"你", "su3 converts to 你");
            s.send(kVK_Delete, @"\x7f");
            checkEq(s.client.markedText, @"", "backspace clears the character");
        }

        { // Down opens candidates, a number key picks one.
            Session s;
            s.type(@"su3");
            check(s.send(kVK_DownArrow, @""), "Down is handled");
            s.type(@"2");
            check(![s.client.markedText isEqualToString:@"你"],
                  "number key picks a different candidate");
            s.send(kVK_Return, @"\r");
            check(s.client.committed.length > 0, "picked candidate commits");
        }

        { // ⌃⌥E toggles forced English, so su3 stays literal.
            Session s;
            s.send(kVK_ANSI_E, @"e",
                   NSEventModifierFlagControl | NSEventModifierFlagOption);
            s.type(@"su3");
            checkEq(s.client.markedText, @"su3", "forced English keeps raw keys");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"su3", "forced English commits raw keys");
        }

        { // ⌃⌥[ and ⌃⌥] produce corner quotes.
            Session s;
            s.send(kVK_ANSI_LeftBracket, @"[",
                   NSEventModifierFlagControl | NSEventModifierFlagOption);
            s.send(kVK_ANSI_RightBracket, @"]",
                   NSEventModifierFlagControl | NSEventModifierFlagOption);
            checkEq(s.client.markedText, @"「」", "ctrl+opt brackets give 「」");
        }

        { // Shifted punctuation: the M2 regression where NSEvent's
          // -charactersIgnoringModifiers dropped Shift and turned "!" into "1".
            Session s;
            s.type(@"su3");
            s.type(@"!");
            // The character must be the shifted one; which form it takes then
            // depends on the punctuation style (Chinese by default here).
            checkEq(s.client.markedText, @"你！", "shift+1 resolves to !, shown as ！");
            s.type(@"@#");
            checkEq(s.client.markedText, @"你！@#",
                    "shift+2 and shift+3 resolve, and stay half-width");
        }

        { // ⌘V pastes into the pre-edit while composing...
            Session s;
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:@"ABC"
                                              forType:NSPasteboardTypeString];
            s.type(@"su3");
            check(s.send(kVK_ANSI_V, @"v", NSEventModifierFlagCommand),
                  "cmd+V is handled while composing");
            checkEq(s.client.markedText, @"你ABC", "pasted text joins the preedit");
        }

        { // ...and is left to the application when there is nothing to paste into.
            Session s;
            check(!s.send(kVK_ANSI_V, @"v", NSEventModifierFlagCommand),
                  "cmd+V passes through with no composition");
        }

        { // ⌃⌥R reopens a committed Chinese selection for candidate editing.
            Session s;
            s.client.documentText = @"測試";
            s.client.selectedRange = NSMakeRange(0, 2);
            check(s.send(kVK_ANSI_R, @"r",
                         NSEventModifierFlagControl | NSEventModifierFlagOption),
                  "ctrl+opt+R starts reconversion on a Chinese selection");
            checkEq(s.client.markedText, @"測試",
                    "the selection reopens as an Ari composition");
            check(NSEqualRanges(s.client.lastMarkedReplacement, NSMakeRange(0, 2)),
                  "the composition replaces the original range");
        }

        { // Escape puts the original text back rather than losing it.
            Session s;
            s.client.documentText = @"測試";
            s.client.selectedRange = NSMakeRange(0, 2);
            s.send(kVK_ANSI_R, @"r",
                   NSEventModifierFlagControl | NSEventModifierFlagOption);
            s.send(kVK_Escape, @"\x1b");
            checkEq(s.client.committed, @"測試",
                    "escape restores the original selection");
        }

        { // Pressed mid-composition: declined, but never leaked to the client,
          // which would make the marked text disappear.
            Session s;
            s.type(@"su3");
            check(s.send(kVK_ANSI_R, @"r",
                         NSEventModifierFlagControl | NSEventModifierFlagOption),
                  "ctrl+opt+R is swallowed while composing");
            checkEq(s.client.markedText, @"你", "the composition survives it");
        }

        { // Nothing to reconvert: the shortcut belongs to the application.
            Session s;
            s.client.documentText = @"hello";
            s.client.selectedRange = NSMakeRange(0, 5);
            check(!s.send(kVK_ANSI_R, @"r",
                          NSEventModifierFlagControl | NSEventModifierFlagOption),
                  "English selection declines reconversion");
            checkEq(s.client.markedText, @"", "the document is left alone");
        }

        { // No selection at all.
            Session s;
            check(!s.send(kVK_ANSI_R, @"r",
                          NSEventModifierFlagControl | NSEventModifierFlagOption),
                  "no selection declines reconversion");
        }

        { // Space with nothing composed is the application's: Quick Look in
          // Finder, play/pause in a media app, activating a focused control.
            Session s;
            check(!s.send(kVK_Space, @" "),
                  "space passes through with no composition");
            checkEq(s.client.markedText, @"", "and starts no composition");
        }

        { // With a composition it is Ari's: tone one, or a literal space.
            Session s;
            s.type(@"su3");
            check(s.send(kVK_Space, @" "), "space is handled while composing");
            checkEq(s.client.markedText, @"你 ", "space joins the composition");
        }

        { // Punctuation follows the system Bopomofo input method: the marks
          // Chinese text uses take their Chinese form with no modifier...
            Session s;
            s.type(@"[");
            checkEq(s.client.markedText, @"「", "[ gives 「");
            s.type(@"]");
            checkEq(s.client.markedText, @"「」", "] gives 」");
            s.type(@"{");
            checkEq(s.client.markedText, @"「」『", "shift+[ gives 『");
            s.type(@"<>?!");
            checkEq(s.client.markedText, @"「」『，。？！",
                    "shifted , . / 1 give ，。？！");
        }

        { // ...while the symbols a programmer types stay half-width.
            Session s;
            s.type(@"@#$%&*+=");
            checkEq(s.client.markedText, @"@#$%&*+=",
                    "programmer symbols stay half-width");
        }

        { // Bopomofo finals are still Bopomofo, not punctuation.
            Session s;
            s.type(@"xu,4");
            checkEq(s.client.markedText, @"列", "',' stays the ㄝ final");
        }

        { // English mode gives plain ASCII punctuation.
            Session s;
            s.send(kVK_ANSI_E, @"e",
                   NSEventModifierFlagControl | NSEventModifierFlagOption);
            s.type(@"[!");
            checkEq(s.client.markedText, @"[!",
                    "English mode keeps punctuation literal");
        }

        { // Uppercase is English, never Bopomofo: acronyms and identifiers
          // survive, and the syllable after them keeps its initial.
            Session s;
            s.type(@"SU3");
            checkEq(s.client.markedText, @"SU3", "uppercase stays literal");
        }

        { // Lowercase is unaffected.
            Session s;
            s.type(@"su3");
            checkEq(s.client.markedText, @"你", "lowercase still composes");
        }

        { // Command shortcuts are never swallowed.
            Session s;
            check(!s.send(kVK_ANSI_C, @"c", NSEventModifierFlagCommand),
                  "cmd+c is passed to the application");
        }

        { // commitComposition flushes rather than losing text (focus change).
            Session s;
            s.type(@"su3");
            [s.controller commitComposition:s.client];
            checkEq(s.client.committed, @"你", "focus loss commits the preedit");
        }

        [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
        printf("\n%d checks, %d failures\n", checks, failures);
        return failures == 0 ? 0 : 1;
    }
}

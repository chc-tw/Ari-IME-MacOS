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

#include "buffer.h"
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

// A remembered adjudication changes what later blocks see, so each one that
// depends on the default reading starts from a clean slate.
void forgetEverything() {
    for (const auto &entry : Buffer::rememberedBoundaries()) {
        Buffer::forgetBoundary(entry.keys);
    }
}

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

    bool buffer_isPicking() { return [controller ari_isPicking]; }
    int page() { return [controller ari_candidatePage]; }
    int caret() { return [controller ari_caretChar]; }
    int pageCount() { return [controller ari_candidatePageCount]; }
    NSString *selectedCharacter() { return [controller ari_selectedCharacter]; }

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

        { // ↓ edits the character before the caret, as macOS input methods do.
            Session s;
            s.type(@"su3cl3");
            checkEq(s.client.markedText, @"你好", "two characters composed");
            s.send(kVK_DownArrow, @"");
            check(s.buffer_isPicking(), "Down opens the candidate window");
            checkEq(s.selectedCharacter(), @"好", "it targets the last character");
        }

        { // Mid-string it targets the character behind the caret, not ahead.
            Session s;
            s.type(@"su3cl3");
            s.send(kVK_LeftArrow, @"");   // caret between 你 and 好
            s.send(kVK_LeftArrow, @"");   // caret before 你
            s.send(kVK_RightArrow, @"");  // caret between 你 and 好 again
            s.send(kVK_DownArrow, @"");
            checkEq(s.selectedCharacter(), @"你",
                    "the character behind the caret is the one edited");
        }

        { // Candidate paging wraps: the page you want is often the last one.
            Session s;
            s.type(@"su3");
            s.send(kVK_DownArrow, @"");
            check(s.pageCount() > 1, "su3 has more than one candidate page");
            checkEq([NSString stringWithFormat:@"%d", s.page()], @"1",
                    "starts on the first page");
            s.send(kVK_LeftArrow, @"");   // ← pages back, and should wrap
            checkEq([NSString stringWithFormat:@"%d", s.page()],
                    [NSString stringWithFormat:@"%d", s.pageCount()],
                    "back from the first page lands on the last");
            s.send(kVK_RightArrow, @"");  // → from the last wraps to the first
            checkEq([NSString stringWithFormat:@"%d", s.page()], @"1",
                    "forward from the last page returns to the first");
        }

        { // ⌘Return picks and leaves the caret beside what changed, instead of
          // returning it to the end of the composition.
            Session s;
            s.type(@"su3cl3");            // 你好
            s.send(kVK_LeftArrow, @"");   // caret between them
            s.send(kVK_DownArrow, @"");   // candidates on 你
            checkEq(s.selectedCharacter(), @"你", "editing the first character");
            s.send(kVK_Return, @"\r", NSEventModifierFlagCommand);
            check(!s.buffer_isPicking(), "the candidate is picked");
            checkEq([NSString stringWithFormat:@"%d", s.caret()], @"1",
                    "the caret stays beside the character that changed");
        }

        { // Plain Return picks and returns the caret to the end.
            Session s;
            s.type(@"su3cl3");
            s.send(kVK_LeftArrow, @"");
            s.send(kVK_DownArrow, @"");
            s.send(kVK_Return, @"\r");
            checkEq([NSString stringWithFormat:@"%d", s.caret()], @"-1",
                    "the caret returns to the end");
        }

        { // Esc leaves the candidate window on the same character, so ↓ reopens
          // that one rather than walking backwards through the line.
            Session s;
            s.type(@"su3cl3ji3");          // 你好我
            s.send(kVK_DownArrow, @"");
            checkEq(s.selectedCharacter(), @"我", "↓ opens on the last character");
            s.send(kVK_Escape, @"\x1b");
            s.send(kVK_DownArrow, @"");
            checkEq(s.selectedCharacter(), @"我",
                    "↓ after Esc reopens the same character");
            s.send(kVK_Escape, @"\x1b");
            s.send(kVK_LeftArrow, @"");    // step one character back
            s.send(kVK_DownArrow, @"");
            checkEq(s.selectedCharacter(), @"好",
                    "← then ↓ moves to the character before it");
        }

        {
            forgetEverything();
          // ↑ asks which reading of an ambiguous run was meant, and picking the
          // all-English one gives the keys back exactly as typed.
            Session s;
            s.type(@"fig4");
            checkEq(s.client.markedText, @"fi是", "fig4 reads as fi + 是");
            s.send(kVK_UpArrow, @"");
            check(!s.buffer_isPicking(),
                  "↑ opens the adjudication list, not the candidate window");
            s.type(@"1");
            checkEq(s.client.markedText, @"fig4", "the first entry is the keys as typed");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"fig4", "and it commits as English");
        }

        {
            forgetEverything();
          // The Chinese reading is still reachable from the same list.
            Session s;
            s.type(@"fig4");
            s.send(kVK_UpArrow, @"");
            s.type(@"2");
            checkEq(s.client.markedText, @"fi是", "the second entry keeps 是");
        }

        {
            forgetEverything();
          // Esc leaves the line exactly as it was.
            Session s;
            s.type(@"fig4");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_Escape, @"\x1b");
            checkEq(s.client.markedText, @"fi是", "Esc changes nothing");
        }

        {
            forgetEverything();
          // A clean syllable is ambiguous too — it could have been meant as the
          // keys themselves — so ↑ offers those, replacing the raw-key entry
          // that used to be buried at the end of the候選 list.
            Session s;
            s.type(@"su3");
            checkEq(s.client.markedText, @"你", "su3 reads as 你");
            s.send(kVK_UpArrow, @"");
            s.type(@"1");
            checkEq(s.client.markedText, @"su3", "↑ then 1 gives the keys back");
        }

        { // Plain English has no reading to choose between, so ↑ falls through.
            Session s;
            s.type(@"README");
            s.send(kVK_UpArrow, @"");
            checkEq(s.client.markedText, @"README", "↑ leaves English alone");
        }

        {
            forgetEverything();
          // The choice is remembered: the point of asking is not to ask again.
            Session first;
            first.type(@"fig4");
            first.send(kVK_UpArrow, @"");
            first.type(@"1");                    // keep it English
            checkEq(first.client.markedText, @"fig4", "taught once");

            Session second;
            second.type(@"fig4");
            second.send(kVK_Return, @"\r");
            checkEq(second.client.committed, @"fig4",
                    "the next fig4 needs no answer");

            // A longer run is a different question, and must not inherit it.
            Session longer;
            longer.type(@"fig46");
            longer.send(kVK_Return, @"\r");
            check(![longer.client.committed isEqualToString:@"fig46"],
                  "a longer run is parsed on its own");

            Buffer::forgetBoundary("fig4");
            Session after;
            after.type(@"fig4");
            checkEq(after.client.markedText, @"fi是", "forgetting restores the rule");
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

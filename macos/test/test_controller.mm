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
#include "zhuyin.h"
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

        { // Opening candidates leaves the caret where it was, after the
          // character being picked, rather than jumping in front of it.
            Session s;
            s.type(@"su3cl3");            // 你好
            const NSUInteger end = s.client.markedSelection.location;
            s.send(kVK_DownArrow, @"");   // candidates on 好
            check(s.buffer_isPicking(), "candidates are open on the last character");
            checkEq([NSString stringWithFormat:@"%lu",
                                (unsigned long)s.client.markedSelection.location],
                    [NSString stringWithFormat:@"%lu", (unsigned long)end],
                    "the caret stays after the character being picked");
            s.send(kVK_Escape, @"");
            s.send(kVK_LeftArrow, @"");   // caret between 你 and 好
            s.send(kVK_DownArrow, @"");   // candidates on 你
            checkEq([NSString stringWithFormat:@"%lu",
                                (unsigned long)s.client.markedSelection.location],
                    @"1", "and after a character in the middle too");
        }

        { // ↑ on the first candidate wraps to the last one on the same page,
          // not to the last page.
            Session s;
            s.type(@"g4");                // 是: several pages of homophones
            s.send(kVK_DownArrow, @"");
            check(s.pageCount() > 1, "ㄕˋ has more than one page");
            s.send(kVK_UpArrow, @"");
            checkEq([NSString stringWithFormat:@"%d", s.page()], @"1",
                    "↑ on the first candidate stays on the page");
            checkEq([NSString stringWithFormat:@"%d", [s.controller ari_highlight]],
                    [NSString stringWithFormat:@"%d",
                                               [s.controller ari_candidatesOnPage] - 1],
                    "and lands on its last candidate");
            s.send(kVK_UpArrow, @"");
            checkEq([NSString stringWithFormat:@"%d", [s.controller ari_highlight]],
                    [NSString stringWithFormat:@"%d",
                                               [s.controller ari_candidatesOnPage] - 2],
                    "then ↑ moves up as usual");
            s.send(kVK_DownArrow, @"");
            s.send(kVK_DownArrow, @"");   // ↓ on the last candidate
            checkEq([NSString stringWithFormat:@"%d", s.page()], @"1",
                    "↓ on the last candidate stays on the page");
            checkEq([NSString stringWithFormat:@"%d", [s.controller ari_highlight]],
                    @"0", "and wraps to its first candidate");
        }

        { // With the setting off, ↑ on the first candidate leaves the page as
          // the core does.
            [NSUserDefaults.standardUserDefaults setBool:NO
                                                  forKey:@"CandidateWrapWithinPage"];
            Session s;
            s.type(@"g4");
            s.send(kVK_DownArrow, @"");
            s.send(kVK_UpArrow, @"");
            check(s.page() != 1, "↑ on the first candidate changes page when off");
            [NSUserDefaults.standardUserDefaults
                removeObjectForKey:@"CandidateWrapWithinPage"];
        }

        { // ↓ after the last character of a phrase offers the phrase itself:
          // 服飾 and 服侍 are re-picked without moving back to 服.
            Session s;
            s.type(@"zj6g4");             // ㄈㄨˊ ㄕˋ
            s.send(kVK_DownArrow, @"");
            NSArray<NSString *> *page = [s.controller ari_candidateTexts];
            check([page containsObject:@"服飾"] && [page containsObject:@"服侍"],
                  "↓ on the phrase's last character lists 服飾 and 服侍");
            NSString *other = [s.client.markedText isEqualToString:@"服飾"]
                                  ? @"服侍" : @"服飾";
            const NSUInteger at = [page indexOfObject:other];
            for (NSUInteger i = 0; i < at; ++i) s.send(kVK_DownArrow, @"");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.markedText, other, "picking it rewrites both characters");
            s.send(kVK_LeftArrow, @"");   // caret between 服 and 飾
            s.send(kVK_DownArrow, @"");   // on 服, the first character
            page = [s.controller ari_candidateTexts];
            check(![page containsObject:@"服飾"] && ![page containsObject:@"服侍"],
                  "the first character offers single characters only");
        }

        { // With the setting off, the phrase is offered at its first character.
            [NSUserDefaults.standardUserDefaults setBool:NO
                                                  forKey:@"PhraseChoiceRearward"];
            Session s;
            s.type(@"zj6g4");
            s.send(kVK_DownArrow, @"");
            NSArray<NSString *> *page = [s.controller ari_candidateTexts];
            check(![page containsObject:@"服飾"], "off: not on the last character");
            s.send(kVK_Escape, @"");
            s.send(kVK_LeftArrow, @"");
            s.send(kVK_DownArrow, @"");
            page = [s.controller ari_candidateTexts];
            check([page containsObject:@"服飾"], "off: on the first character");
            [NSUserDefaults.standardUserDefaults
                removeObjectForKey:@"PhraseChoiceRearward"];
        }

        { // ⌥ + digit types a full-width digit while punctuation is Chinese:
          // straight to the application with nothing composed, into the
          // composition otherwise.
            Session s;
            check(s.send(kVK_ANSI_1, @"¡", NSEventModifierFlagOption),
                  "⌥1 is handled with Chinese punctuation");
            checkEq(s.client.committed, @"１", "⌥1 commits a full-width 1");
            s.type(@"su3");
            s.send(kVK_ANSI_2, @"™", NSEventModifierFlagOption);
            checkEq(s.client.markedText, @"你２", "⌥2 joins the composition");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"１你２", "and commits with it");
        }

        { // With English punctuation the layout's own ⌥ character is kept.
            [NSUserDefaults.standardUserDefaults setObject:@"English"
                                                    forKey:@"PunctuationStyle"];
            Session s;
            check(!s.send(kVK_ANSI_1, @"¡", NSEventModifierFlagOption),
                  "⌥1 goes to the application with English punctuation");
            checkEq(s.client.committed, @"", "and Ari inserts nothing");
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"PunctuationStyle"];
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

        { // Shift+← marks characters for a custom phrase; Enter adds it and
          // keeps composing rather than committing.
            Session s;
            s.type(@"su3cl4");
            s.send(kVK_LeftArrow, @"", NSEventModifierFlagShift);
            s.send(kVK_LeftArrow, @"", NSEventModifierFlagShift);
            NSString *status = [s.controller ari_markStatus];
            check([status hasPrefix:@"Enter 加入自訂詞「"],
                  "Shift+← twice marks two characters to add");
            NSString *phrase = s.client.markedText;
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"", "Enter adds the phrase instead of committing");
            checkEq(s.client.markedText, phrase, "and the composition stays as it was");
            Zhuyin dictionary;
            check(dictionary.forgetUserPhrase(phrase.UTF8String) > 0,
                  "the phrase was added to the user dictionary");
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
          // The list opens on the reading already shown, so ↑ then Enter keeps
          // the text and remembers nothing. It used to open on the all-English
          // reading, and that one stray Enter made 2u/4 English for good.
            Session s;
            s.type(@"2u/4");
            NSString *shown = s.client.markedText;
            check(shown.length == 1, "2u/4 reads as one character");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.markedText, shown, "↑ then Enter keeps the character");
            check(Buffer::rememberedBoundaries().empty(), "and remembers nothing");
        }

        {
            forgetEverything();
          // A remembered all-English answer can be changed from the keyboard,
          // even when its keys include / (ㄥ), which is not a letter or digit.
            {
                Session s;
                s.type(@"2u/4");
                s.send(kVK_UpArrow, @"");
                s.type(@"1");
                checkEq(s.client.markedText, @"2u/4", "1 picks the keys as typed");
                s.send(kVK_Return, @"\r");
            }
            NSString *chinese = nil;
            {
                Session s;
                s.type(@"2u/4");
                checkEq(s.client.markedText, @"2u/4", "the answer is remembered");
                s.send(kVK_UpArrow, @"");
                s.type(@"3");
                chinese = s.client.markedText;
                check(chinese.length == 1 && ![chinese isEqualToString:@"4"],
                      "↑ on the remembered keys offers the character again");
                s.send(kVK_Return, @"\r");
            }
            {
                Session s;
                s.type(@"2u/4");
                checkEq(s.client.markedText, chinese, "and the new answer sticks");
            }
            forgetEverything();
        }

        {
            forgetEverything();
          // ↑ steps onto the character it asks about, but the caret stays
          // after it while the list is open and after Esc closes it.
            Session s;
            s.type(@"fig4");
            const NSUInteger end = s.client.markedSelection.location;
            s.send(kVK_UpArrow, @"");
            checkEq([NSString stringWithFormat:@"%lu",
                                (unsigned long)s.client.markedSelection.location],
                    [NSString stringWithFormat:@"%lu", (unsigned long)end],
                    "the caret stays put while ↑ asks");
            s.send(kVK_Escape, @"\x1b");
            checkEq([NSString stringWithFormat:@"%lu",
                                (unsigned long)s.client.markedSelection.location],
                    [NSString stringWithFormat:@"%lu", (unsigned long)end],
                    "and after Esc");
        }

        { // ↑ with nothing to ask about leaves the caret where it was.
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"KeySymbolsReading"];
            Session s;
            s.type(@"hello");
            s.send(kVK_LeftArrow, @"");
            const int before = s.caret();
            s.send(kVK_UpArrow, @"");
            if (!s.buffer_isPicking()) {
                checkEq([NSString stringWithFormat:@"%d", s.caret()],
                        [NSString stringWithFormat:@"%d", before],
                        "↑ on plain English does not move the caret");
            }
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"KeySymbolsReading"];
        }

        { // With key symbols on, plain English is askable too; the caret on
          // screen stays put while the list is open, and Esc changes nothing.
            Session s;
            s.type(@"hello");
            s.send(kVK_LeftArrow, @"");
            const int before = s.caret();
            const NSUInteger shown = s.client.markedSelection.location;
            s.send(kVK_UpArrow, @"");
            checkEq([NSString stringWithFormat:@"%lu",
                                (unsigned long)s.client.markedSelection.location],
                    [NSString stringWithFormat:@"%lu", (unsigned long)shown],
                    "the caret stays put while ↑ asks about English");
            s.send(kVK_Escape, @"\x1b");
            checkEq(s.client.markedText, @"hello", "Esc leaves the English alone");
            checkEq([NSString stringWithFormat:@"%d", s.caret()],
                    [NSString stringWithFormat:@"%d", before], "and the caret too");
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

        {
            forgetEverything();
          // Any run of 注音 keys can become its symbols, syllable or not: cc
          // is ㄏㄏ in one step instead of one key at a time.
            Session s;
            s.type(@"cc");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_UpArrow, @"");     // from the keys (shown) to the last entry
            s.send(kVK_Return, @"\r");
            checkEq(s.client.markedText, @"ㄏㄏ", "↑ turns cc into ㄏㄏ");
            check(Buffer::rememberedBoundaries().empty(), "symbols are not remembered");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"ㄏㄏ", "and they commit as typed");
        }

        {
            forgetEverything();
          // A run starting with a tone key reads as its mark first, and is
          // still treated as symbols, not remembered.
            Session s;
            s.type(@"3c");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.markedText, @"ˇㄏ", "3c reads key by key as ˇㄏ");
            check(Buffer::rememberedBoundaries().empty(), "and is not remembered");
        }

        { // With the setting off, cc has nothing to offer and stays as typed.
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"KeySymbolsReading"];
            Session s;
            s.type(@"cc");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"cc", "off: ↑ offers nothing for cc");
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"KeySymbolsReading"];
        }

        { // Plain English has no reading to choose between, so ↑ falls through.
            Session s;
            s.type(@"README");
            s.send(kVK_UpArrow, @"");
            checkEq(s.client.markedText, @"README", "↑ leaves English alone");
        }

        {
            forgetEverything();
          // A key that is not a character yet is asked about too, and its
          // Bopomofo symbol is one of the readings.
            Session s;
            s.type(@"1");
            s.send(kVK_UpArrow, @"");
            s.type(@"2");
            checkEq(s.client.markedText, @"ㄅ", "↑ on a lone 1 offers ㄅ");
            s.type(@"u4");
            check([s.client.markedText hasPrefix:@"ㄅ"],
                  "the symbol is finished text; typing continues after it");
        }

        {
            forgetEverything();
          // Asking must not freeze the key: Esc leaves it composing, so the
          // syllable can still be finished.
            Session s;
            s.type(@"1");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_Escape, @"\x1b");
            checkEq(s.client.markedText, @"1", "Esc leaves the key as typed");
            s.type(@"u4");
            checkEq(s.client.markedText, @"必", "and 1 + u4 still makes 必");
        }

        {
            forgetEverything();
          // A full syllable offers its symbols as well, and they stay symbols.
            Session s;
            s.type(@"su3");
            s.send(kVK_UpArrow, @"");
            s.send(kVK_DownArrow, @"");   // from 你 (shown) to the last entry, the symbols
            s.send(kVK_Return, @"\r");
            checkEq(s.client.markedText, @"ㄋㄧˇ", "su3 offers ㄋㄧˇ last");
            s.send(kVK_Return, @"\r");
            checkEq(s.client.committed, @"ㄋㄧˇ", "and commits it unchanged");
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
            // A tone key ends a token, so keys typed afterwards start a new
            // one and simply follow the remembered prefix.
            Session longer;
            longer.type(@"fig46");
            longer.send(kVK_Return, @"\r");
            checkEq(longer.client.committed, @"fig46",
                    "later keys append to the remembered reading");

            Buffer::forgetBoundary("fig4");
            Session after;
            after.type(@"fig4");
            checkEq(after.client.markedText, @"fi是", "forgetting restores the rule");
        }

        {
            forgetEverything();
          // A remembered answer must stay changeable. Applying it turns the
          // token back into keys, and asking again has to still work on those
          // keys — otherwise the first answer would be permanent.
            Session teach;
            teach.type(@"fig4");
            teach.send(kVK_UpArrow, @"");
            teach.type(@"1");
            checkEq(teach.client.markedText, @"fig4", "taught to stay English");

            // The answer lands as the syllable converts, so the text never
            // changes under the user a keystroke later.
            Session again;
            again.type(@"fig4");
            checkEq(again.client.markedText, @"fig4",
                    "the remembered answer is there as it is typed");
            again.send(kVK_UpArrow, @"");
            again.type(@"2");
            checkEq(again.client.markedText, @"fi是", "and it can be changed back");

            Session third;
            third.type(@"fig4");
            third.send(kVK_Return, @"\r");
            checkEq(third.client.committed, @"fi是", "the new answer sticks");
            forgetEverything();
        }

        { // A key Ari does not claim must not take the composition with it.
          // ⌥, produces ≤, which no layout maps to ASCII.
            Session s;
            s.type(@"su3");
            checkEq(s.client.markedText, @"你", "composing");
            check(!s.send(kVK_ANSI_Comma, @"≤", NSEventModifierFlagOption),
                  "the key goes to the application");
            checkEq(s.client.committed, @"你", "the composition is committed first");
            checkEq(s.client.markedText, @"", "and nothing is left marked");
        }

        { // Tab is the same story: unhandled while composing.
            Session s;
            s.type(@"su3");
            s.send(kVK_Tab, @"\t");
            checkEq(s.client.committed, @"你", "Tab commits rather than losing it");
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

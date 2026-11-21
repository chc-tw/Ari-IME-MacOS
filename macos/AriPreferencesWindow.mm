// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import "AriPreferencesWindow.h"

#include "AriPreferences.h"
#include "buffer.h"
#include "layout.h"
#include "zhuyin.h"

namespace {

// The layouts, in the order layout.h declares them.
NSArray<NSString *> *layoutNames() {
    NSMutableArray *names = [NSMutableArray array];
    for (int i = static_cast<int>(ari_ime::KeyboardLayout::Default);
         i <= static_cast<int>(ari_ime::KeyboardLayout::Colemak); ++i) {
        const auto layout = static_cast<ari_ime::KeyboardLayout>(i);
        [names addObject:@(ari_ime::keyboardLayoutName(layout))];
    }
    return names;
}

// The stable strings the config uses, shared with the Fcitx5 build.
NSArray<NSString *> *layoutValues() {
    return @[@"Default", @"Eten", @"Hsu", @"Ibm", @"GinYieh", @"Dvorak",
             @"Carpalx", @"ColemakDhAnsi", @"ColemakDhOrth", @"Workman",
             @"Colemak"];
}

NSTextField *label(NSString *text) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.alignment = NSTextAlignmentRight;
    return field;
}

NSTextField *hint(NSString *text) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:11];
    field.textColor = NSColor.secondaryLabelColor;
    return field;
}

} // namespace

// One row of a memory list. The two kinds answer different questions — which
// homophone, and English or Chinese — so they are listed separately rather
// than merged into one table the user would have to disentangle.
@interface AriMemoryRow : NSObject
@property(nonatomic, copy) NSString *subject;  // the keys or the phrase
@property(nonatomic, copy) NSString *outcome;  // what they resolve to
@end

@implementation AriMemoryRow
@end

@implementation AriPreferencesWindow {
    NSWindow *_window;
    NSPopUpButton *_layout;
    NSPopUpButton *_punctuation;
    NSPopUpButton *_arrows;
    NSButton *_showBopomofo;
    NSButton *_uppercaseIsEnglish;
    NSButton *_caretStaysAfterPick;
    NSButton *_autoLearn;
    NSButton *_showStatusLine;
    NSButton *_spaceCandidateMode;
    NSPopUpButton *_punctuationShortcut;
    NSTableView *_boundaries;
    NSTableView *_phrases;
    NSMutableArray<AriMemoryRow *> *_boundaryRows;
    NSMutableArray<AriMemoryRow *> *_phraseRows;
}

+ (instancetype)shared {
    static AriPreferencesWindow *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[AriPreferencesWindow alloc] init];
    });
    return shared;
}

- (void)show {
    if (!_window) {
        [self build];
    }
    [self load];
    [self loadMemory];
    // An input method is an agent with no Dock tile, so it has to ask for the
    // foreground explicitly or the window opens behind whatever the user is
    // typing into.
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
    [_window center];
}

// --- Building -------------------------------------------------------------

- (NSPopUpButton *)popUpWithTitles:(NSArray<NSString *> *)titles {
    NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                       pullsDown:NO];
    [button addItemsWithTitles:titles];
    button.target = self;
    button.action = @selector(settingChanged:);
    return button;
}

- (NSButton *)checkboxWithTitle:(NSString *)title {
    NSButton *button = [NSButton checkboxWithTitle:title
                                            target:self
                                            action:@selector(settingChanged:)];
    return button;
}

- (NSGridView *)generalPane {
    _layout = [self popUpWithTitles:layoutNames()];
    _punctuation = [self popUpWithTitles:@[@"中文（，。「」？！）", @"英文（半形）"]];
    _arrows = [self popUpWithTitles:@[@"← → 換頁（macOS 慣例）",
                                      @"← → 移動字元（Linux 版行為）"]];
    _showBopomofo = [self checkboxWithTitle:@"打字時顯示注音"];
    _uppercaseIsEnglish = [self checkboxWithTitle:@"大寫字母一律當英文"];
    _caretStaysAfterPick = [self checkboxWithTitle:@"⌘Return 選字後游標留在原地"];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ label(@"鍵盤配列"), _layout ],
        @[ [NSGridCell emptyContentView], hint(@"注音鍵盤的按鍵對應。") ],
        @[ label(@"標點符號"), _punctuation ],
        @[ [NSGridCell emptyContentView],
           hint(@"中文模式下標點的形式。@ # $ % 等符號一律保持半形。") ],
        @[ label(@"候選左右鍵"), _arrows ],
        @[ [NSGridCell emptyContentView],
           hint(@"候選視窗開啟時 ← → 的行為。⌥← ⌥→ 一律移動字元。") ],
        @[ [NSGridCell emptyContentView], _showBopomofo ],
        @[ [NSGridCell emptyContentView],
           hint(@"在預編輯區旁顯示目前音節的讀音，例如 ㄏㄨㄢ。") ],
        @[ [NSGridCell emptyContentView], _uppercaseIsEnglish ],
        @[ [NSGridCell emptyContentView],
           hint(@"讓 API、UI、HTTP 這類縮寫不會被讀成注音。") ],
        @[ [NSGridCell emptyContentView], _caretStaysAfterPick ],
        @[ [NSGridCell emptyContentView],
           hint(@"一般選字後游標回到行尾；⌘Return 則留在剛改動的字旁邊。") ],
    ]];
    grid.columnSpacing = 10;
    grid.rowSpacing = 6;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    return grid;
}

- (NSGridView *)advancedPane {
    _autoLearn = [self checkboxWithTitle:@"記住選過的字詞"];
    _showStatusLine = [self checkboxWithTitle:@"顯示狀態列（中/英 · 配列 · 標點）"];
    _spaceCandidateMode = [self checkboxWithTitle:@"用空白鍵開啟候選視窗"];
    _punctuationShortcut = [self popUpWithTitles:@[@"⌃⇧", @"⌥⇧", @"⌃", @"⌥", @"停用"]];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [NSGridCell emptyContentView], _autoLearn ],
        @[ [NSGridCell emptyContentView],
           hint(@"選過的字會在相同上下文優先出現，約一天內淡出。密碼欄位一律不記。") ],
        @[ [NSGridCell emptyContentView], _showStatusLine ],
        @[ [NSGridCell emptyContentView], _spaceCandidateMode ],
        @[ [NSGridCell emptyContentView],
           hint(@"開啟後，完整音節加空白鍵會開候選，而不是輸入一聲。") ],
        @[ label(@"中文標點修飾鍵"), _punctuationShortcut ],
        @[ [NSGridCell emptyContentView],
           hint(@"標點設為英文時，臨時輸入中文標點的修飾鍵。") ],
    ]];
    grid.columnSpacing = 10;
    grid.rowSpacing = 6;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    return grid;
}

// --- Memory pane ----------------------------------------------------------

- (NSTableView *)tableWithFirstColumn:(NSString *)first
                        secondColumn:(NSString *)second {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *subject = [[NSTableColumn alloc] initWithIdentifier:@"subject"];
    subject.title = first;
    subject.width = 150;
    NSTableColumn *outcome = [[NSTableColumn alloc] initWithIdentifier:@"outcome"];
    outcome.title = second;
    outcome.width = 220;
    [table addTableColumn:subject];
    [table addTableColumn:outcome];
    table.dataSource = self;
    table.allowsMultipleSelection = YES;
    table.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    return table;
}

- (NSView *)memoryPane {
    _boundaryRows = [NSMutableArray array];
    _phraseRows = [NSMutableArray array];
    _boundaries = [self tableWithFirstColumn:@"按鍵" secondColumn:@"選擇"];
    _phrases = [self tableWithFirstColumn:@"詞彙" secondColumn:@"讀音"];

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        hint(@"中英裁決 — ↑ 選過的組合，下次自動套用"),
        [self scrolling:_boundaries],
        [NSButton buttonWithTitle:@"刪除選取的裁決"
                           target:self
                           action:@selector(forgetBoundaries:)],
        hint(@"自訂詞 — 組字時 Shift+←/→ 標記，按 Enter 加入"),
        [self scrolling:_phrases],
        [NSButton buttonWithTitle:@"刪除選取的自訂詞"
                           target:self
                           action:@selector(forgetPhrases:)],
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);
    return stack;
}

- (NSScrollView *)scrolling:(NSTableView *)table {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    [scroll.heightAnchor constraintEqualToConstant:110].active = YES;
    [scroll.widthAnchor constraintEqualToConstant:400].active = YES;
    return scroll;
}

- (void)loadMemory {
    [_boundaryRows removeAllObjects];
    for (const auto &entry : Buffer::rememberedBoundaries()) {
        AriMemoryRow *row = [[AriMemoryRow alloc] init];
        row.subject = @(entry.keys.c_str());
        row.outcome = @((entry.english + entry.chinese).c_str());
        [_boundaryRows addObject:row];
    }
    [_phraseRows removeAllObjects];
    {
        Zhuyin dictionary;
        for (const auto &phrase : dictionary.userPhrases()) {
            AriMemoryRow *row = [[AriMemoryRow alloc] init];
            row.subject = @(phrase.phrase.c_str());
            row.outcome = @(phrase.reading.c_str());
            [_phraseRows addObject:row];
        }
    }
    [_boundaries reloadData];
    [_phrases reloadData];
}

- (void)forgetBoundaries:(id)sender {
    (void)sender;
    [_boundaries.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      (void)stop;
      if (i < self->_boundaryRows.count) {
          Buffer::forgetBoundary(self->_boundaryRows[i].subject.UTF8String ?: "");
      }
    }];
    [self loadMemory];
}

- (void)forgetPhrases:(id)sender {
    (void)sender;
    // One context for the whole removal: opening a chewing context is not
    // cheap, and it writes the dictionary out when it goes away.
    Zhuyin dictionary;
    NSMutableArray<NSString *> *doomed = [NSMutableArray array];
    [_phrases.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      (void)stop;
      if (i < self->_phraseRows.count) {
          [doomed addObject:self->_phraseRows[i].subject];
      }
    }];
    for (NSString *phrase in doomed) {
        dictionary.forgetUserPhrase(phrase.UTF8String ?: "");
    }
    [self loadMemory];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table {
    return table == _boundaries ? (NSInteger)_boundaryRows.count
                                : (NSInteger)_phraseRows.count;
}

- (id)tableView:(NSTableView *)table
    objectValueForTableColumn:(NSTableColumn *)column
                          row:(NSInteger)row {
    NSArray<AriMemoryRow *> *rows = table == _boundaries ? _boundaryRows : _phraseRows;
    if (row < 0 || row >= (NSInteger)rows.count) {
        return @"";
    }
    return [column.identifier isEqualToString:@"subject"] ? rows[row].subject
                                                          : rows[row].outcome;
}

- (void)build {
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 460, 390)];
    NSTabViewItem *general = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
    general.label = @"一般";
    general.view = [self paneContaining:[self generalPane]];
    NSTabViewItem *advanced = [[NSTabViewItem alloc] initWithIdentifier:@"advanced"];
    advanced.label = @"進階";
    advanced.view = [self paneContaining:[self advancedPane]];
    NSTabViewItem *memory = [[NSTabViewItem alloc] initWithIdentifier:@"memory"];
    memory.label = @"記憶";
    memory.view = [self memoryPane];
    [tabs addTabViewItem:general];
    [tabs addTabViewItem:advanced];
    [tabs addTabViewItem:memory];

    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 480, 430)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _window.title = @"Ari 輸入法設定";
    _window.releasedWhenClosed = NO;
    _window.contentView = tabs;
}

- (NSView *)paneContaining:(NSView *)content {
    NSView *pane = [[NSView alloc] initWithFrame:NSZeroRect];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [pane addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:pane.topAnchor constant:20],
        [content.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor constant:20],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:pane.trailingAnchor
                                                         constant:-20],
    ]];
    return pane;
}

// --- Reading and writing NSUserDefaults ------------------------------------

- (void)load {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    const ari::Preferences preferences = ari::currentPreferences();

    const NSUInteger layoutIndex =
        [layoutValues() indexOfObject:([defaults stringForKey:@"KeyboardLayout"]
                                           ?: @"Default")];
    [_layout selectItemAtIndex:layoutIndex == NSNotFound ? 0
                                                        : (NSInteger)layoutIndex];
    [_punctuation selectItemAtIndex:
                      preferences.punctuationStyle == ari::PunctuationStyle::Chinese
                          ? 0
                          : 1];
    [_arrows selectItemAtIndex:
                 preferences.arrowStyle == ari::ArrowStyle::MacOS ? 0 : 1];
    _showBopomofo.state = preferences.showBopomofo ? NSControlStateValueOn
                                                   : NSControlStateValueOff;
    _uppercaseIsEnglish.state =
        preferences.uppercaseIsEnglish ? NSControlStateValueOn : NSControlStateValueOff;
    _caretStaysAfterPick.state =
        preferences.caretStaysAfterPick ? NSControlStateValueOn : NSControlStateValueOff;
    _autoLearn.state = preferences.autoLearn ? NSControlStateValueOn
                                             : NSControlStateValueOff;
    _showStatusLine.state = preferences.showStatusLine ? NSControlStateValueOn
                                                       : NSControlStateValueOff;
    _spaceCandidateMode.state = preferences.spaceCandidateMode
                                    ? NSControlStateValueOn
                                    : NSControlStateValueOff;
    [_punctuationShortcut
        selectItemAtIndex:static_cast<NSInteger>(preferences.punctuationShortcut)];
}

- (void)settingChanged:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:layoutValues()[(NSUInteger)_layout.indexOfSelectedItem]
                 forKey:@"KeyboardLayout"];
    [defaults setObject:(_punctuation.indexOfSelectedItem == 0 ? @"Chinese"
                                                               : @"English")
                 forKey:@"PunctuationStyle"];
    [defaults setObject:(_arrows.indexOfSelectedItem == 0 ? @"MacOS" : @"Linux")
                 forKey:@"CandidateArrowKeys"];
    [defaults setBool:_showBopomofo.state == NSControlStateValueOn
               forKey:@"ShowBopomofo"];
    [defaults setBool:_uppercaseIsEnglish.state == NSControlStateValueOn
               forKey:@"UppercaseIsEnglish"];
    [defaults setBool:_caretStaysAfterPick.state == NSControlStateValueOn
               forKey:@"CaretStaysAfterPick"];
    [defaults setBool:_autoLearn.state == NSControlStateValueOn forKey:@"AutoLearn"];
    [defaults setBool:_showStatusLine.state == NSControlStateValueOn
               forKey:@"ShowStatusLine"];
    [defaults setBool:_spaceCandidateMode.state == NSControlStateValueOn
               forKey:@"SpaceCandidateMode"];
    static NSArray<NSString *> *shortcuts =
        @[@"ControlShift", @"AltShift", @"Control", @"Alt", @"Disabled"];
    [defaults setObject:shortcuts[(NSUInteger)_punctuationShortcut.indexOfSelectedItem]
                 forKey:@"ChinesePunctuationShortcut"];
}

@end

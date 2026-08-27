// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import "AriCandidateWindow.h"

namespace {

constexpr CGFloat kCandidateFontSize = 15;
constexpr CGFloat kAuxFontSize = 11;
constexpr CGFloat kRowPaddingY = 3;
constexpr CGFloat kRowPaddingX = 8;
constexpr CGFloat kNumberGap = 8;
constexpr CGFloat kPanelPadding = 8;
constexpr CGFloat kAuxGap = 4;
constexpr CGFloat kCornerRadius = 5;

NSFont *candidateFont() { return [NSFont systemFontOfSize:kCandidateFontSize]; }
NSFont *auxFont() { return [NSFont systemFontOfSize:kAuxFontSize]; }

NSSize measure(NSString *text, NSFont *font) {
    if (text.length == 0) {
        return NSZeroSize;
    }
    return [text sizeWithAttributes:@{NSFontAttributeName : font}];
}

} // namespace

// The list itself. Drawn rather than composed from subviews so the number
// column lines up: every row shares one column width, and the selection is a
// rounded band behind a whole row instead of a background colour on a run of
// text. It takes no mouse events — the panel must never take focus from the
// application being typed into, and picking by number is what the keys are for.
@interface AriCandidateListView : NSView
@property(nonatomic, copy) NSArray<NSString *> *candidates;
@property(nonatomic) NSInteger highlight;
@property(nonatomic, copy) NSString *auxUp;
@property(nonatomic, copy) NSString *auxDown;
@end

@implementation AriCandidateListView

- (BOOL)isFlipped {
    return YES;
}

- (CGFloat)numberColumnWidth {
    if (self.candidates.count == 0) {
        return 0;
    }
    // One width for every row, measured on the widest label actually shown.
    CGFloat widest = 0;
    for (NSUInteger i = 0; i < self.candidates.count; ++i) {
        NSString *number = [NSString stringWithFormat:@"%lu.", (unsigned long)(i + 1)];
        widest = MAX(widest, measure(number, candidateFont()).width);
    }
    return widest;
}

- (CGFloat)rowHeight {
    return ceil(measure(@"字", candidateFont()).height) + kRowPaddingY * 2;
}

- (NSSize)intrinsicContentSize {
    const CGFloat numbers = [self numberColumnWidth];
    CGFloat widest = 0;
    for (NSString *candidate in self.candidates) {
        widest = MAX(widest, ceil(measure(candidate, candidateFont()).width));
    }
    CGFloat width = self.candidates.count > 0
                        ? numbers + kNumberGap + widest + kRowPaddingX * 2
                        : 0;
    CGFloat height = [self rowHeight] * (CGFloat)self.candidates.count;

    for (NSString *aux in @[ self.auxUp ?: @"", self.auxDown ?: @"" ]) {
        if (aux.length == 0) {
            continue;
        }
        const NSSize size = measure(aux, auxFont());
        width = MAX(width, ceil(size.width) + kRowPaddingX * 2);
        height += ceil(size.height) + kAuxGap;
    }
    return NSMakeSize(MAX(width, 40) + kPanelPadding * 2,
                      height + kPanelPadding * 2);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat y = kPanelPadding;
    const CGFloat left = kPanelPadding;
    const CGFloat contentWidth = NSWidth(self.bounds) - kPanelPadding * 2;

    if (self.auxUp.length > 0) {
        const NSSize size = measure(self.auxUp, auxFont());
        [self.auxUp drawAtPoint:NSMakePoint(left + kRowPaddingX, y)
                 withAttributes:@{
                     NSFontAttributeName : auxFont(),
                     NSForegroundColorAttributeName : NSColor.secondaryLabelColor
                 }];
        y += ceil(size.height) + kAuxGap;
    }

    const CGFloat numbers = [self numberColumnWidth];
    const CGFloat rowHeight = [self rowHeight];
    for (NSUInteger i = 0; i < self.candidates.count; ++i) {
        const BOOL selected = (NSInteger)i == self.highlight;
        const NSRect row = NSMakeRect(left, y, contentWidth, rowHeight);
        if (selected) {
            NSBezierPath *band = [NSBezierPath bezierPathWithRoundedRect:row
                                                                xRadius:kCornerRadius
                                                                yRadius:kCornerRadius];
            [NSColor.selectedContentBackgroundColor setFill];
            [band fill];
        }
        NSColor *textColor = selected ? NSColor.selectedMenuItemTextColor
                                      : NSColor.labelColor;
        NSDictionary *numberAttributes = @{
            NSFontAttributeName : candidateFont(),
            NSForegroundColorAttributeName :
                selected ? textColor : NSColor.tertiaryLabelColor
        };
        NSString *number = [NSString stringWithFormat:@"%lu.", (unsigned long)(i + 1)];
        const NSSize numberSize = measure(number, numberAttributes[NSFontAttributeName]);
        // Right-align the numbers so the candidates start on one line.
        [number drawAtPoint:NSMakePoint(left + kRowPaddingX + numbers - numberSize.width,
                                        y + kRowPaddingY)
             withAttributes:numberAttributes];
        [self.candidates[i]
            drawAtPoint:NSMakePoint(left + kRowPaddingX + numbers + kNumberGap,
                                    y + kRowPaddingY)
         withAttributes:@{
             NSFontAttributeName : candidateFont(),
             NSForegroundColorAttributeName : textColor
         }];
        y += rowHeight;
    }

    if (self.auxDown.length > 0) {
        y += kAuxGap;
        [self.auxDown drawAtPoint:NSMakePoint(left + kRowPaddingX, y)
                   withAttributes:@{
                       NSFontAttributeName : auxFont(),
                       NSForegroundColorAttributeName : NSColor.secondaryLabelColor
                   }];
    }
}

@end

@implementation AriCandidateWindow {
    NSPanel *_panel;
    AriCandidateListView *_list;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 120, 40)
                  styleMask:NSWindowStyleMaskBorderless |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:YES];
    // Never take focus from the application being typed into, and float above
    // full-screen windows.
    _panel.level = NSPopUpMenuWindowLevel;
    _panel.hidesOnDeactivate = NO;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.opaque = NO;
    _panel.ignoresMouseEvents = YES;

    NSVisualEffectView *background =
        [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    background.material = NSVisualEffectMaterialMenu;
    background.state = NSVisualEffectStateActive;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 8;
    background.layer.masksToBounds = YES;
    _panel.contentView = background;

    _list = [[AriCandidateListView alloc] initWithFrame:NSZeroRect];
    _list.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:_list];
    [NSLayoutConstraint activateConstraints:@[
        [_list.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],
        [_list.trailingAnchor constraintEqualToAnchor:background.trailingAnchor],
        [_list.topAnchor constraintEqualToAnchor:background.topAnchor],
        [_list.bottomAnchor constraintEqualToAnchor:background.bottomAnchor],
    ]];
    return self;
}

- (void)showCandidates:(NSArray<NSString *> *)candidates
             highlight:(NSInteger)highlight
                 auxUp:(NSString *)auxUp
               auxDown:(NSString *)auxDown
                atRect:(NSRect)caretRect {
    if (candidates.count == 0 && auxUp.length == 0 && auxDown.length == 0) {
        [self hide];
        return;
    }

    _list.candidates = candidates ?: @[];
    _list.highlight = highlight;
    _list.auxUp = auxUp ?: @"";
    _list.auxDown = auxDown ?: @"";
    [_list invalidateIntrinsicContentSize];
    [_list setNeedsDisplay:YES];

    const NSSize fit = _list.intrinsicContentSize;
    NSRect frame = NSMakeRect(NSMinX(caretRect), 0, fit.width, fit.height);
    // Prefer below the caret; flip above when the panel would run off-screen.
    frame.origin.y = NSMinY(caretRect) - frame.size.height - 4;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(NSMakePoint(NSMinX(caretRect), NSMinY(caretRect)),
                          candidate.frame)) {
            screen = candidate;
            break;
        }
    }
    if (screen && frame.origin.y < NSMinY(screen.visibleFrame)) {
        frame.origin.y = NSMaxY(caretRect) + 4;
    }
    if (screen && NSMaxX(frame) > NSMaxX(screen.visibleFrame)) {
        frame.origin.x = NSMaxX(screen.visibleFrame) - frame.size.width;
    }

    [_panel setFrame:frame display:YES];
    [_panel orderFrontRegardless];
}

- (void)hide {
    [_panel orderOut:nil];
}

@end

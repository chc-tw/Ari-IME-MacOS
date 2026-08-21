// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import "AriCandidateWindow.h"

@implementation AriCandidateWindow {
    NSPanel *_panel;
    NSTextField *_label;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 240, 80)
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:YES];
    // The panel must never steal focus from the application being typed into,
    // and must float above full-screen windows.
    _panel.level = NSPopUpMenuWindowLevel;
    _panel.hidesOnDeactivate = NO;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.opaque = NO;

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    background.material = NSVisualEffectMaterialMenu;
    background.state = NSVisualEffectStateActive;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 8;
    _panel.contentView = background;

    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:15];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.allowsDefaultTighteningForTruncation = NO;
    [background addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_label.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:10],
        [_label.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-10],
        [_label.topAnchor constraintEqualToAnchor:background.topAnchor constant:8],
        [_label.bottomAnchor constraintEqualToAnchor:background.bottomAnchor constant:-8],
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

    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    NSDictionary *dim = @{NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
                          NSFontAttributeName : [NSFont systemFontOfSize:11]};
    NSDictionary *plain = @{NSForegroundColorAttributeName : NSColor.labelColor,
                            NSFontAttributeName : [NSFont systemFontOfSize:15]};
    NSDictionary *selected = @{
        NSForegroundColorAttributeName : NSColor.selectedMenuItemTextColor,
        NSBackgroundColorAttributeName : NSColor.selectedContentBackgroundColor,
        NSFontAttributeName : [NSFont systemFontOfSize:15]
    };

    if (auxUp.length > 0) {
        [text appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:[auxUp stringByAppendingString:@"\n"]
                                             attributes:dim]];
    }
    for (NSUInteger i = 0; i < candidates.count; ++i) {
        NSString *line = [NSString stringWithFormat:@" %lu. %@ ",
                                                    (unsigned long)(i + 1),
                                                    candidates[i]];
        [text appendAttributedString:
                  [[NSAttributedString alloc]
                      initWithString:line
                          attributes:((NSInteger)i == highlight ? selected : plain)]];
        if (i + 1 < candidates.count) {
            [text appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:@"\n"
                                                 attributes:plain]];
        }
    }
    if (auxDown.length > 0) {
        [text appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:[@"\n" stringByAppendingString:auxDown]
                                             attributes:dim]];
    }

    _label.attributedStringValue = text;
    [_label sizeToFit];
    const NSSize fit = _label.fittingSize;
    NSRect frame = NSMakeRect(NSMinX(caretRect), 0, fit.width + 20, fit.height + 16);
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

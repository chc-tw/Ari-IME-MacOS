// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import "AriHUD.h"

@implementation AriHUD {
    NSPanel *_panel;
    NSTextField *_label;
    NSUInteger _generation;
}

+ (instancetype)shared {
    static AriHUD *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[AriHUD alloc] init];
    });
    return shared;
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
    _panel.level = NSPopUpMenuWindowLevel;
    _panel.hidesOnDeactivate = NO;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.ignoresMouseEvents = YES; // a hint, never a target
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.opaque = NO;

    NSVisualEffectView *background =
        [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    background.material = NSVisualEffectMaterialHUDWindow;
    background.state = NSVisualEffectStateActive;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 10;
    _panel.contentView = background;

    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:18 weight:NSFontWeightMedium];
    _label.alignment = NSTextAlignmentCenter;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_label.leadingAnchor constraintEqualToAnchor:background.leadingAnchor
                                             constant:16],
        [_label.trailingAnchor constraintEqualToAnchor:background.trailingAnchor
                                              constant:-16],
        [_label.topAnchor constraintEqualToAnchor:background.topAnchor
                                         constant:10],
        [_label.bottomAnchor constraintEqualToAnchor:background.bottomAnchor
                                            constant:-10],
    ]];
    return self;
}

- (void)show:(NSString *)message atRect:(NSRect)caretRect {
    if (message.length == 0) {
        return;
    }
    _label.stringValue = message;
    const NSSize fit = _label.fittingSize;
    NSRect frame = NSMakeRect(NSMinX(caretRect), NSMaxY(caretRect) + 8,
                              fit.width + 32, fit.height + 20);

    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(NSMakePoint(NSMinX(caretRect), NSMinY(caretRect)),
                          candidate.frame)) {
            screen = candidate;
            break;
        }
    }
    if (screen) {
        if (NSMaxY(frame) > NSMaxY(screen.visibleFrame)) {
            frame.origin.y = NSMinY(caretRect) - frame.size.height - 8;
        }
        if (NSMaxX(frame) > NSMaxX(screen.visibleFrame)) {
            frame.origin.x = NSMaxX(screen.visibleFrame) - frame.size.width;
        }
    }

    [_panel setFrame:frame display:YES];
    [_panel orderFrontRegardless];

    // Only the newest message may dismiss the panel, so a burst of hints does
    // not leave it flickering.
    const NSUInteger generation = ++_generation;
    __weak AriHUD *weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          AriHUD *strongSelf = weakSelf;
          if (strongSelf && strongSelf->_generation == generation) {
              [strongSelf hide];
          }
        });
}

- (void)hide {
    [_panel orderOut:nil];
}

@end

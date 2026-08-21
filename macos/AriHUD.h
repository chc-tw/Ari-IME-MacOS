// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// The transient hint Fcitx5 shows through showCustomInputMethodInformation:
// 中/英 on a mode toggle, and one-line action results such as 已忘記.
#ifndef ARI_MACOS_HUD_H
#define ARI_MACOS_HUD_H

#import <Cocoa/Cocoa.h>

@interface AriHUD : NSObject

+ (instancetype)shared;

// Shows `message` near `caretRect` (screen coordinates) and hides it again
// after a short delay. A newer message replaces an older one immediately.
- (void)show:(NSString *)message atRect:(NSRect)caretRect;
- (void)hide;

@end

#endif // ARI_MACOS_HUD_H

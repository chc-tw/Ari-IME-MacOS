// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_MACOS_PREFERENCES_WINDOW_H
#define ARI_MACOS_PREFERENCES_WINDOW_H

#import <Cocoa/Cocoa.h>

// The settings window, reached from the input menu. Everything it writes goes
// to the same NSUserDefaults keys documented for `defaults write`, and the
// engine re-reads them on the next keystroke, so changes apply immediately.
@interface AriPreferencesWindow : NSObject <NSTableViewDataSource>

+ (instancetype)shared;
- (void)show;

@end

#endif // ARI_MACOS_PREFERENCES_WINDOW_H

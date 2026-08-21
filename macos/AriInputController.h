// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_MACOS_INPUT_CONTROLLER_H
#define ARI_MACOS_INPUT_CONTROLLER_H

#import <InputMethodKit/InputMethodKit.h>

// One controller per input context, mirroring Fcitx5's InputerState. It owns a
// Buffer and does nothing but translate between the client and that state
// machine.
@interface AriInputController : IMKInputController
@end

#endif // ARI_MACOS_INPUT_CONTROLLER_H

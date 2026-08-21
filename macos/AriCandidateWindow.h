// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Ari draws its own candidate panel instead of using IMKCandidates, because
// the input contract needs the two auxiliary lines that IMKCandidates has no
// concept of: the editing preview (which character is being re-picked) and the
// page / status line. This is the M2 minimum: a readable list that mirrors
// Buffer's candidate/highlight/page state.
#ifndef ARI_MACOS_CANDIDATE_WINDOW_H
#define ARI_MACOS_CANDIDATE_WINDOW_H

#import <Cocoa/Cocoa.h>

@interface AriCandidateWindow : NSObject

// `auxUp` is the editing preview, `auxDown` the page/status line; either may
// be empty. `origin` is the caret rectangle reported by the client, in screen
// coordinates.
- (void)showCandidates:(NSArray<NSString *> *)candidates
             highlight:(NSInteger)highlight
                 auxUp:(NSString *)auxUp
               auxDown:(NSString *)auxDown
                atRect:(NSRect)caretRect;
- (void)hide;

@end

#endif // ARI_MACOS_CANDIDATE_WINDOW_H

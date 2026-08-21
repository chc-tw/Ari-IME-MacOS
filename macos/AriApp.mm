// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Input method server entry point. macOS launches this bundle on demand when
// the user selects Ari in the input menu; it then serves one
// AriInputController per input context.
#import <Cocoa/Cocoa.h>

#include <cstring>
#import <InputMethodKit/InputMethodKit.h>

#import <Carbon/Carbon.h>

#import "AriInputController.h"

// Held for the process lifetime: IMKServer must outlive every controller.
static IMKServer *gServer = nil;

// `AriIME --register` publishes this bundle to Text Input Services so it shows
// up in System Settings without a logout. Used by macos/install-local.sh.
static int registerInputSource(void) {
    @autoreleasepool {
        NSURL *url = NSBundle.mainBundle.bundleURL;
        const OSStatus status = TISRegisterInputSource((__bridge CFURLRef)url);
        if (status != noErr) {
            NSLog(@"Ari IME: TISRegisterInputSource failed (%d)", (int)status);
            return 1;
        }
        return 0;
    }
}

int main(int argc, const char *argv[]) {
    if (argc > 1 && strcmp(argv[1], "--register") == 0) {
        return registerInputSource();
    }
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *connectionName =
            [bundle objectForInfoDictionaryKey:@"InputMethodConnectionName"];
        if (connectionName.length == 0) {
            NSLog(@"Ari IME: InputMethodConnectionName missing from Info.plist");
            return 1;
        }
        gServer = [[IMKServer alloc] initWithName:connectionName
                                 bundleIdentifier:bundle.bundleIdentifier];
        if (!gServer) {
            NSLog(@"Ari IME: failed to create IMKServer for %@", connectionName);
            return 1;
        }
        [NSApplication sharedApplication];
        [NSApp run];
    }
    return 0;
}

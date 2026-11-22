#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regenerate macos/AriIME.icns (the app icon) and macos/ari.tiff (the input
# menu icon). Both are 注 set in PingFang TC, drawn with AppKit.
#
# The menu icon is a template: black on transparent, 16 pt with a 2x
# representation, so macOS sizes it like its own input sources and tints it for
# light and dark menu bars (Info.plist sets TISIconIsTemplate). A full-colour
# 32 px image at 72 dpi reads as 32 pt and sits crooked in the menu bar.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/render.m" <<'OBJC'
#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>

static NSString *const kGlyph = @"注";

static NSColor *rgb(unsigned hex) {
  return [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0
                             green:((hex >> 8) & 0xff) / 255.0
                              blue:(hex & 0xff) / 255.0
                             alpha:1];
}

// Draw the glyph centred on `box` by its ink bounds, not its line box, so it
// sits optically in the middle.
static void drawGlyph(CGContextRef cg, NSRect box, CGFloat size, NSColor *color) {
  NSFont *font = [NSFont fontWithName:@"PingFangTC-Semibold" size:size]
                     ?: [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
  NSAttributedString *text = [[NSAttributedString alloc]
      initWithString:kGlyph
          attributes:@{NSFontAttributeName : font,
                       NSForegroundColorAttributeName : color}];
  CTLineRef line =
      CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
  const CGRect ink = CTLineGetImageBounds(line, cg);
  CGContextSetTextPosition(cg, NSMidX(box) - ink.size.width / 2 - ink.origin.x,
                           NSMidY(box) - ink.size.height / 2 - ink.origin.y);
  CTLineDraw(line, cg);
  CFRelease(line);
}

// The menu template: a rounded square with the glyph knocked out.
static void drawMenu(CGContextRef cg, CGFloat px) {
  const CGFloat s = px / 16.0;
  const NSRect box = NSMakeRect(1 * s, 1 * s, 14 * s, 14 * s);
  [NSColor.blackColor setFill];
  [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 * s yRadius:3 * s] fill];
  CGContextSetBlendMode(cg, kCGBlendModeDestinationOut);
  drawGlyph(cg, box, 11 * s, NSColor.blackColor);
  CGContextSetBlendMode(cg, kCGBlendModeNormal);
}

// The app icon, on Apple's 1024 grid: an 824 rounded square with a soft
// shadow, a teal gradient, and the glyph in paper white.
static void drawApp(CGContextRef cg, CGFloat px) {
  const CGFloat s = px / 1024.0;
  const NSRect box = NSMakeRect(100 * s, 100 * s, 824 * s, 824 * s);
  NSBezierPath *shape =
      [NSBezierPath bezierPathWithRoundedRect:box xRadius:185 * s yRadius:185 * s];
  [NSGraphicsContext saveGraphicsState];
  NSShadow *shadow = [[NSShadow alloc] init];
  shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
  shadow.shadowOffset = NSMakeSize(0, -10 * s);
  shadow.shadowBlurRadius = 20 * s;
  [shadow set];
  [rgb(0x2f5d62) setFill];
  [shape fill];
  [NSGraphicsContext restoreGraphicsState];
  NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:rgb(0x4a8a8f)
                                                       endingColor:rgb(0x24494d)];
  [gradient drawInBezierPath:shape angle:-90];
  drawGlyph(cg, NSOffsetRect(box, 0, 8 * s), 540 * s, rgb(0xf7f4ed));
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    const bool menu = strcmp(argv[2], "menu") == 0;
    NSImage *menuImage = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
    for (int i = 3; i < argc; ++i) {
      const int px = atoi(argv[i]);
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
          initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSCalibratedRGBColorSpace
                       bytesPerRow:0 bitsPerPixel:0];
      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext *ctx =
          [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
      NSGraphicsContext.currentContext = ctx;
      (menu ? drawMenu : drawApp)(ctx.CGContext, px);
      [NSGraphicsContext restoreGraphicsState];
      if (menu) {
        // Every representation is 16 pt; the pixel count makes it 1x or 2x.
        rep.size = NSMakeSize(16, 16);
        [menuImage addRepresentation:rep];
        continue;
      }
      [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
          writeToFile:[NSString stringWithFormat:@"%s/%s-%d.png", argv[1],
                                                 argv[2], px]
           atomically:YES];
    }
    if (menu) {
      [[menuImage TIFFRepresentationUsingCompression:NSTIFFCompressionLZW
                                              factor:0]
          writeToFile:[NSString stringWithFormat:@"%s/menu.tiff", argv[1]]
           atomically:YES];
    }
  }
  return 0;
}
OBJC
clang -o "$work/render" "$work/render.m" -framework Cocoa -framework CoreText
"$work/render" "$work" app 16 32 64 128 256 512 1024
"$work/render" "$work" menu 16 32

iconset="$work/AriIME.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    cp "$work/app-$size.png" "$iconset/icon_${size}x${size}.png"
done
for pair in "16 32" "32 64" "128 256" "256 512" "512 1024"; do
    set -- $pair
    cp "$work/app-$2.png" "$iconset/icon_$1x$1@2x.png"
done
iconutil -c icns "$iconset" -o macos/AriIME.icns

# One TIFF holding the 16 px (1x) and 32 px (2x) representations, both 16 pt.
cp "$work/menu.tiff" macos/ari.tiff

printf 'wrote macos/AriIME.icns (%s bytes) and macos/ari.tiff\n' \
    "$(stat -f %z macos/AriIME.icns)"

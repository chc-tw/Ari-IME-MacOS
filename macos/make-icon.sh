#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regenerate macos/AriIME.icns and macos/ari.tiff from data/inputer.svg.
#
# Rendering goes through NSImage rather than qlmanage, which hangs often enough
# to be unusable in a build step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/render.m" <<'OBJC'
// Draws data/inputer.svg's geometry directly. NSImage cannot read SVG, and
// qlmanage hangs often enough to be unusable in a build step; the icon is
// eleven rectangles, so draw them.
#import <Cocoa/Cocoa.h>

static NSColor *paper(void) {
  return [NSColor colorWithSRGBRed:0xf7 / 255.0 green:0xf4 / 255.0
                              blue:0xed / 255.0 alpha:1];
}
static NSColor *ink(void) {
  return [NSColor colorWithSRGBRed:0x2f / 255.0 green:0x5d / 255.0
                              blue:0x62 / 255.0 alpha:1];
}

// The SVG is a 64x64 viewBox with y running downwards.
static NSRect box(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat scale) {
  return NSMakeRect(x * scale, (64 - y - h) * scale, w * scale, h * scale);
}
static void fill(NSRect r, CGFloat radius, NSColor *color) {
  [color setFill];
  [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
}

static void draw(CGFloat size) {
  const CGFloat s = size / 64.0;
  fill(box(0, 0, 64, 64, s), 14 * s, paper());
  fill(box(14, 14, 36, 36, s), 0, ink());
  [paper() setStroke];
  NSBezierPath *frame = [NSBezierPath bezierPathWithRect:box(18, 18, 28, 28, s)];
  frame.lineWidth = 2 * s;
  [frame stroke];
  const CGFloat marks[][4] = {
      {23, 21, 4, 6}, {22, 31, 4, 4},  {23, 39, 4, 6},  {31, 20, 4, 24},
      {29, 24, 13, 4}, {29, 32, 13, 4}, {29, 40, 13, 4}};
  for (unsigned i = 0; i < sizeof(marks) / sizeof(marks[0]); ++i) {
    fill(box(marks[i][0], marks[i][1], marks[i][2], marks[i][3], s), 1 * s,
         paper());
  }
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    for (int i = 2; i < argc; ++i) {
      const int size = atoi(argv[i]);
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
          initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSCalibratedRGBColorSpace
                       bytesPerRow:0 bitsPerPixel:0];
      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext.currentContext =
          [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
      draw(size);
      [NSGraphicsContext restoreGraphicsState];
      [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
          writeToFile:[NSString stringWithFormat:@"%s/%d.png", argv[1], size]
           atomically:YES];
    }
  }
  return 0;
}
OBJC
clang -o "$work/render" "$work/render.m" -framework Cocoa
"$work/render" "$work" 16 32 64 128 256 512 1024

iconset="$work/AriIME.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    cp "$work/$size.png" "$iconset/icon_${size}x${size}.png"
done
for pair in "16 32" "32 64" "128 256" "256 512" "512 1024"; do
    set -- $pair
    cp "$work/$2.png" "$iconset/icon_$1x$1@2x.png"
done
iconutil -c icns "$iconset" -o macos/AriIME.icns

# The menu bar wants a small template-sized image, not the full icon.
sips -s format tiff "$work/32.png" --out macos/ari.tiff >/dev/null

printf 'wrote macos/AriIME.icns (%s bytes) and macos/ari.tiff\n' \
    "$(stat -f %z macos/AriIME.icns)"

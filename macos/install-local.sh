#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the development build of Ari IME into the current user's
# ~/Library/Input Methods and register it with Text Input Services.
#
# Nothing outside the user's own Input Methods folder is touched, and the
# script never edits the active input source list: after running it, add
# "Ari IME" yourself in System Settings > Keyboard > Input Sources.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${ARI_BUILD_DIR:-$repo_root/build-macos/ari}"
app="$build_dir/AriIME.app"
dest_dir="$HOME/Library/Input Methods"
dest="$dest_dir/AriIME.app"

if [[ ! -d "$app" ]]; then
    printf 'Build not found: %s\n' "$app" >&2
    printf 'Run cmake --build %s first.\n' "$build_dir" >&2
    exit 1
fi

# A previously registered copy keeps running; stop it so the new binary loads.
pkill -x AriIME 2>/dev/null || true

mkdir -p "$dest_dir"
rm -rf "$dest"
cp -R "$app" "$dest"

# Ad-hoc signature: macOS refuses to load an unsigned input method bundle.
# With no Developer ID there is no verified identity behind the app, so the
# lists that would name the developer fall back to the signing identifier —
# which is why an unnamed build shows up as its bundle id. Give the identifier
# the name we want shown until the app is signed properly (M5).
codesign --force --deep --identifier "Ari IME" --sign - "$dest"

# Register the bundle so it appears in System Settings > Input Sources.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$dest"
"$dest/Contents/MacOS/AriIME" --register

printf 'Installed: %s\n' "$dest"
printf '\nNext:\n'
printf '  1. System Settings > Keyboard > Input Sources > + > 繁體中文 > Ari IME\n'
printf '  2. LOG OUT AND BACK IN (or reboot).\n'
printf '\n'
printf 'Step 2 is required, not optional. Text Input Services caches input\n'
printf 'method properties and only launches input method servers for sources\n'
printf 'that were present at login. Without it the input source is selectable\n'
printf 'but its server never starts, so keystrokes vanish silently, and\n'
printf 'Info.plist changes such as Caps Lock switching are ignored.\n'
printf '\n'
printf 'During development, restart the server without logging out:\n'
printf '  pkill -x AriIME && open -b %s\n' \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$dest/Contents/Info.plist" 2>/dev/null)"

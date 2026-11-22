#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install Ari IME from a release zip into ~/Library/Input Methods.
#
# Run it with bash rather than double-clicking it: a downloaded script is
# quarantined, and macOS blocks opening it directly but not handing it to bash.
#   bash ~/Downloads/AriIME-*/install.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$here/AriIME.app"
dest_dir="$HOME/Library/Input Methods"
dest="$dest_dir/AriIME.app"

if [[ ! -d "$app" ]]; then
    printf '找不到 AriIME.app，請在解壓縮後的資料夾裡執行這個腳本。\n' >&2
    exit 1
fi

# An earlier version keeps running until stopped, and would stay loaded.
pkill -x AriIME 2>/dev/null || true

mkdir -p "$dest_dir"
rm -rf "$dest"
ditto "$app" "$dest"

# The app is not signed with an Apple Developer ID, so a downloaded copy is
# quarantined and macOS refuses to start it. This is the step that needs the
# user's trust: it tells macOS to run this copy anyway.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$dest"
"$dest/Contents/MacOS/AriIME" --register

printf '已安裝到 %s\n\n' "$dest"
printf '接下來：\n'
printf '  1. 系統設定 → 鍵盤 → 輸入方式 → 編輯… → ＋ → 繁體中文 → Ari IME\n'
printf '  2. 登出再登入（或重新開機）。第一次安裝一定要做，否則選了輸入法也打不出字。\n'
printf '\n更新版本時只要重新執行這個腳本，不用再登出。\n'

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove Ari IME. Your custom phrases and settings are kept unless you pass
# --purge.
#   bash ~/Downloads/AriIME-*/uninstall.sh [--purge]
set -euo pipefail

dest="$HOME/Library/Input Methods/AriIME.app"
data="$HOME/Library/Application Support/AriIME"

pkill -x AriIME 2>/dev/null || true
rm -rf "$dest"
printf '已移除 %s\n' "$dest"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$data"
    printf '已刪除使用者資料 %s\n' "$data"
else
    printf '使用者資料（自訂詞、設定）保留在 %s\n' "$data"
    printf '要一併刪除，請加上 --purge 再執行一次。\n'
fi
printf '\n請到 系統設定 → 鍵盤 → 輸入方式 把 Ari IME 移除，然後登出再登入。\n'

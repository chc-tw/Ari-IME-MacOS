#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build a release zip of Ari IME for macOS, and optionally publish it as a
# GitHub Release.
#
#   macos/release.sh                 build, test and package into dist/
#   macos/release.sh --publish       ...then push, tag and create the release
#   macos/release.sh -n 2 --publish  second macOS build of the same version
#
# The app is ad-hoc signed, not signed with an Apple Developer ID, so users
# install it with the bundled install.sh, which clears the quarantine flag.
# The tag is v<version>-macos.<n>, where <version> comes from the root
# CMakeLists.txt (the upstream release this fork is merged up to).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

build_number=1
publish=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--build-number) build_number="$2"; shift 2 ;;
        --publish) publish=true; shift ;;
        -h|--help) sed -n '3,14p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

version="$(sed -n 's/^project(ari-ime VERSION \([0-9.]*\).*/\1/p' CMakeLists.txt)"
tag="v${version}-macos.${build_number}"
name="AriIME-${version}-macos.${build_number}"
build_dir="$repo_root/build-macos/release"
chewing="$repo_root/build-macos/libchewing-install"
dist="$repo_root/dist"
stage="$dist/$name"
zip="$dist/$name.zip"

# A release must be reproducible from the published source: no local edits.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    printf 'The working tree has uncommitted changes; commit them first.\n' >&2
    exit 1
fi
if $publish && git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    printf 'Tag %s already exists; pass -n with the next build number.\n' "$tag" >&2
    exit 1
fi

printf '==> %s (%s)\n' "$name" "$(git rev-parse --short HEAD)"

if [[ ! -f "$chewing/lib/libchewing.a" ]]; then
    printf '==> building libchewing\n'
    macos/build-libchewing.sh
fi

printf '==> configure and build\n'
cmake -S macos -B "$build_dir" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON \
    -DCHEWING_INCLUDE_DIR="$chewing/include" \
    -DCHEWING_LIBRARY="$chewing/lib/libchewing.a" \
    -DCHEWING_DATA_DIR="$chewing/share/libchewing" >/dev/null
cmake --build "$build_dir" -j "$(sysctl -n hw.ncpu)" >/dev/null

# test_buffer is upstream's suite; it carries the failures this fork expects
# by design (docs/core-divergence.md), so it is reported but not gating.
printf '==> tests\n'
(cd "$build_dir" && ctest -E '^(test_buffer|test_user_data)$' --output-on-failure) | tail -3
# test_user_data is upstream's too. On macOS chewing.dat is the one user
# dictionary (D18), so its userdict.dat migration checks cannot hold; those
# three are allowed, and any other failure stops the release.
allowed_user_data='FAIL migration setup has legacy userdict.dat
FAIL migration seeds chewing.dat
FAIL migration preserves userdict.dat'
user_data_failures="$(cd "$build_dir" &&
    ctest -R '^test_user_data$' --output-on-failure 2>&1 | grep -E '^FAIL' || true)"
if [[ "$user_data_failures" != "$allowed_user_data" ]]; then
    printf 'test_user_data failed beyond the known D18 checks:\n%s\n' \
        "$user_data_failures" >&2
    exit 1
fi
printf 'test_user_data: only the 3 known D18 checks fail\n'
(cd "$build_dir" && ctest -R '^test_buffer$' --output-on-failure 2>&1) |
    grep -E '^FAIL|checks' || true

app="$build_dir/AriIME.app"
reported="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist")"
if [[ "$reported" != "$version" ]]; then
    printf 'The app reports %s, expected %s.\n' "$reported" "$version" >&2
    exit 1
fi

printf '==> package\n'
rm -rf "$stage" "$zip"
mkdir -p "$stage"
ditto "$app" "$stage/AriIME.app"
# Same ad-hoc signature as a local install; macOS will not load an unsigned
# input method at all.
codesign --force --deep --identifier "Ari IME" --sign - "$stage/AriIME.app"
codesign --verify --deep --strict "$stage/AriIME.app"
cp macos/dist/install.sh macos/dist/uninstall.sh macos/dist/README.txt LICENSE \
    "$stage/"
ditto -c -k --keepParent "$stage" "$zip"
sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
printf '    %s\n    sha256 %s\n' "$zip" "$sha"

notes="$dist/$name-notes.md"
cat > "$notes" <<NOTES
Ari IME ${version} 的 macOS 版（第 ${build_number} 版）。

**需求**：Apple Silicon（M 系列晶片）Mac，macOS 14 以上。

## 安裝

1. 下載 \`${name}.zip\` 並解壓縮。
2. 打開「終端機」，執行：
   \`\`\`
   bash ~/Downloads/${name}/install.sh
   \`\`\`
3. 系統設定 → 鍵盤 → 輸入方式 → 編輯… → ＋ → 繁體中文 → Ari IME
4. 登出再登入。第一次安裝一定要做。

這個 App 沒有 Apple Developer ID 簽名，直接打開會被 macOS 擋下；安裝腳本會清除
下載檔的隔離標記，讓 macOS 執行它。不放心的話，可以檢查原始碼或自己編譯。

更新時重新執行 \`install.sh\` 即可，自訂詞與設定會保留。更新前已經開著的 App
要重新開啟才打得出中文（或直接登出再登入）。

SHA-256：\`${sha}\`

原始碼：https://github.com/chc-tw/Ari-IME-MacOS/tree/${tag}（GPL-3.0-or-later）
NOTES

if ! $publish; then
    printf '\nNot published. Release notes: %s\n' "$notes"
    printf 'Run again with --publish to push, tag and create the release.\n'
    exit 0
fi

printf '==> publish %s\n' "$tag"
branch="$(git rev-parse --abbrev-ref HEAD)"
git push -u origin "$branch"
git tag -a "$tag" -m "Ari IME ${version} for macOS, build ${build_number}"
git push origin "$tag"
gh release create "$tag" "$zip" --repo chc-tw/Ari-IME-MacOS \
    --title "Ari IME ${version}（macOS）" --notes-file "$notes" --verify-tag

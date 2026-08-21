#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build libchewing (static) and its dictionary data for the macOS build.
#
# Homebrew has no libchewing formula, and libchewing 0.12's CMake install
# rules cannot export a static build (the Rust staticlib target is not in any
# export set). So the two artifacts Ari needs — the static library and the
# compiled dictionaries — are produced directly with cargo and chewing-cli.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Upstream development moved from GitHub to Codeberg; the GitHub repository is
# a stale mirror whose newest tag is v0.12.0. Ari's CI validates against the
# libchewing that Arch ships, so match that release.
want_version="${LIBCHEWING_VERSION:-0.13.1}"
source_dir="${LIBCHEWING_SOURCE_DIR:-$repo_root/third_party/libchewing}"
out_dir="${LIBCHEWING_OUT_DIR:-$repo_root/build-macos/libchewing-install}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

if [[ ! -f "$source_dir/capi/include/chewing.h" ]]; then
    printf 'libchewing source not found at %s\n' "$source_dir" >&2
    printf 'git clone --depth 1 --branch v%s https://codeberg.org/chewing/libchewing.git third_party/libchewing\n' \
        "$want_version" >&2
    exit 1
fi
if [[ ! -f "$source_dir/data/CMakeLists.txt" ]]; then
    printf 'Initialising libchewing data submodule\n'
    git -C "$source_dir" submodule update --init --depth 1 data
fi

# libchewing 0.12 needs Rust >= 1.88; Homebrew's rust may be older, so prefer
# a rustup toolchain when one is installed.
if [[ -x "$HOME/.cargo/bin/cargo" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"

printf '==> cargo build (chewing_capi, chewing-cli)\n'
cargo build --release --manifest-path "$source_dir/Cargo.toml" \
    -p chewing_capi -p chewing-cli

lib="$source_dir/target/release/libchewing_capi.a"
cli="$source_dir/target/release/chewing-cli"

printf '==> staging into %s\n' "$out_dir"
rm -rf "$out_dir"
mkdir -p "$out_dir/include" "$out_dir/lib" "$out_dir/share/libchewing"
cp "$source_dir"/capi/include/*.h "$out_dir/include/"
cp "$lib" "$out_dir/lib/libchewing.a"

printf '==> building dictionaries\n'
for name in word tsi alt mini; do
    "$cli" init --csv "$source_dir/data/dict/chewing/$name.csv" \
        "$out_dir/share/libchewing/$name.dat" >/dev/null
done
cp "$source_dir/data/misc/swkb.dat" "$source_dir/data/misc/symbols.dat" \
    "$out_dir/share/libchewing/"

printf '\nlibchewing staged:\n'
printf '  header : %s\n' "$out_dir/include/chewing.h"
printf '  library: %s\n' "$out_dir/lib/libchewing.a"
printf '  data   : %s\n' "$out_dir/share/libchewing"

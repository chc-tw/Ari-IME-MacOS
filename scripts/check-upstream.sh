#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Report what upstream has changed in src/ since this fork touched it.
#
# The macOS port reuses upstream's input core verbatim wherever it can; the
# exceptions are listed in docs/core-divergence.md. This script answers the two
# questions that matter for keeping that list short:
#   1. Has upstream changed src/ at all since we last looked?
#   2. Has it changed any of the functions we modified?
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

upstream_url="${ARI_UPSTREAM_URL:-https://github.com/kaiyasi/Ari-IME.git}"
upstream_branch="${ARI_UPSTREAM_BRANCH:-main}"

# Functions this fork has modified. Keep in step with docs/core-divergence.md.
divergent_symbols=(
    pendingSyllable      # D1
    tryPeelEnglish       # D2
    tryPeelEnglishTone1  # D2
    setUppercaseIsEnglish # D3
    bodyIsPeelable       # D3
    handleChar           # D3
    setLearningAllowed   # D7
    pickCandidate        # D8
    freezeRun            # D8
    moveAutoCommit       # D8
    learnFromCells       # D8
    handleBackspace      # D8, D12
    runReadings_         # D8 (every live-run reset must clear runOverrides_)
    forgetHighlightedCandidate # D8
    boundaryAlternatives # D13
    chooseBoundaryAlternative # D13, D15
    chooseAndRememberBoundaryAlternative # D15
    tokenStart # D15
    alternativesForKeys # D13, D16
    buildSelCands # D14
    "Zhuyin::Zhuyin"     # D9
    resetAll             # D9
    addUserPhrase        # D9
    forgetUserPhrase     # D9
    handleCaret          # D10
    exitSelection        # D10
)

if ! git remote get-url upstream >/dev/null 2>&1; then
    printf '==> adding upstream remote: %s\n' "$upstream_url"
    git remote add upstream "$upstream_url"
fi

printf '==> fetching upstream\n'
if ! git fetch --quiet upstream "$upstream_branch" 2>/dev/null; then
    printf 'Could not fetch %s (%s). Offline?\n' "$upstream_url" "$upstream_branch" >&2
    exit 1
fi

base="$(git merge-base HEAD "upstream/$upstream_branch" 2>/dev/null || true)"
if [[ -z "$base" ]]; then
    printf 'No common ancestor with upstream/%s.\n' "$upstream_branch" >&2
    exit 1
fi

printf '\n=== upstream commits touching src/ since %s ===\n' "${base:0:9}"
new_commits="$(git log --oneline "$base..upstream/$upstream_branch" -- src/ || true)"
if [[ -z "$new_commits" ]]; then
    printf '(none — the core is in step with upstream)\n'
else
    printf '%s\n' "$new_commits"

    printf '\n=== of those, commits touching functions this fork changed ===\n'
    hit=0
    while read -r sha _; do
        [[ -n "$sha" ]] || continue
        patch="$(git show --format= --unified=0 "$sha" -- src/)"
        for symbol in "${divergent_symbols[@]}"; do
            if printf '%s' "$patch" | grep -q "$symbol"; then
                printf '  %s  <-- touches %s\n' \
                    "$(git log --oneline -1 "$sha")" "$symbol"
                hit=1
                break
            fi
        done
    done <<<"$new_commits"
    if [[ "$hit" -eq 0 ]]; then
        printf '(none — upstream changed src/, but not where we did)\n'
    else
        printf '\nReview docs/core-divergence.md before merging those.\n'
    fi
fi

printf '\n=== this fork'\''s own changes to src/ ===\n'
own="$(git diff --stat "$base..HEAD" -- src/ || true)"
if [[ -z "$own" ]]; then
    printf '(none)\n'
else
    printf '%s\n' "$own"
    printf '\nFull diff: git diff %s..HEAD -- src/\n' "${base:0:9}"
fi

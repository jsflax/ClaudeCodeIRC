#!/usr/bin/env bash
# run-all.sh — runs the v0.0.1 smoke suite end-to-end and prints a
# PASS/FAIL summary table. Each case lives in `c{N}-*.sh`, exits 0
# on pass / non-zero on fail, and writes diagnostic artefacts to
# `/tmp/ccirc-smoke-c{N}/`.
#
# Usage:
#   scripts/smoke/run-all.sh             # run C1..C9 in sequence
#   scripts/smoke/run-all.sh c3 c5       # run only the named cases
#
# Exits 0 iff every selected case passes.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CASES=(
    "c1:c1-3p-chat.sh:3-peer LAN host/join + chat"
    "c2:c2-3p-ask-singleselect.sh:3-peer single-select Ask majority"
    "c3:c3-ask-focus-leak.sh:AskQuestion focus-leak repro"
    "c4:c4-stuck-thinking.sh:stuck-thinking on Ctrl+C rejoin"
    "c5:c5-peer-esc.sh:peer-ESC interrupt fanout (3 peers)"
    "c6:c6-3p-discussion.sh:AskComment discussion sync (3 peers)"
    "c7:c7-3p-approval.sh:tool approval Y/A/D quorum (3 peers)"
    "c8:c8-3p-multiselect.sh:multi-select Ask wait-for-all (3 peers)"
    "c9:c9-keystroke-latency.sh:perf non-regression — keystroke latency"
    "c10:c10-first-run-nick.sh:first-run nick picker overlay"
    "c11:c11-auto-diff.sh:Edit/Write diff renders in auto mode (post-exec resultMeta)"
)

# Optional case filter — if args are passed, only run those cases.
if [[ $# -gt 0 ]]; then
    SELECTED=()
    for entry in "${CASES[@]}"; do
        IFS=':' read -r id _ _ <<<"$entry"
        for arg in "$@"; do
            if [[ "$arg" == "$id" ]]; then
                SELECTED+=("$entry")
                break
            fi
        done
    done
    CASES=("${SELECTED[@]}")
fi

declare -a RESULTS
SUITE_FAILED=0

for entry in "${CASES[@]}"; do
    IFS=':' read -r id script desc <<<"$entry"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $id — $desc"
    echo "═══════════════════════════════════════════════════════════════"
    START="$(date +%s)"
    if "$SCRIPT_DIR/$script"; then
        END="$(date +%s)"
        RESULTS+=("$id  PASS  $((END - START))s  $desc")
    else
        END="$(date +%s)"
        RESULTS+=("$id  FAIL  $((END - START))s  $desc")
        SUITE_FAILED=1
    fi
done

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  v0.0.1 smoke suite — summary"
echo "═══════════════════════════════════════════════════════════════"
for line in "${RESULTS[@]}"; do
    echo "  $line"
done
echo

if [[ "$SUITE_FAILED" -eq 0 ]]; then
    echo "  ✓ all cases PASS — ship it"
    exit 0
else
    echo "  ✗ at least one case FAILED — block tag, triage from /tmp/ccirc-smoke-c*/"
    exit 1
fi

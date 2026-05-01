#!/usr/bin/env bash
# C9 — Perf non-regression: keystroke latency post-question.
#
# The user reported a typing/scrolling slowdown after AskUserQuestion
# answered. Profiling found `FileLogHandler.log` was the dominant hot
# path. Fix: gated the log body behind `#if NCURSESUI_DEBUG_LOG`
# (NCursesUI compile flag, off by default).
#
# This case guards against re-introduction:
#   1. Drive alice into the post-question state (1 Ask answered).
#   2. Run `sample` against the alice pid for 4s while typing 30
#      chars in the main composer at 50ms intervals.
#   3. Assert `FileLogHandler.log` does NOT appear in the top of the
#      sample's call-tree output.
#
# Solo case (alice only) — the regression was UI-local.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c9"

ARTIFACTS="/tmp/ccirc-smoke-c9"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn alice solo ==="
setup_solo
host_session 0 alice "$SMOKE_ROOM_NAME"
ALICE_LATTICE="$(wait_for_lattice "$ALICE_DIR" 20 || true)"
[[ -z "$ALICE_LATTICE" ]] && smoke_die "no alice lattice"

echo
echo "=== phase 2: trigger and answer one Ask to enter post-question state ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude use AskUserQuestion to ask 'Pick a color' (single-select; options Red, Green, Blue, Purple). Output nothing else." Enter

wait_for_ask_count "$ALICE_LATTICE" 1 180 || smoke_die "AskQuestion never materialised"
sleep 2
# Solo answer: Enter on row 0 commits the single-select.
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter
wait_for_ask_status "$ALICE_LATTICE" answered 1 5 || smoke_die "Q never reached .answered"
echo "  Q answered — alice now in post-question render state"

echo
echo "=== phase 3: locate alice pid ==="
APP_PID="$(pgrep -f "CCIRC_DATA_DIR.*$ALICE_DIR" | head -1 || true)"
[[ -z "$APP_PID" ]] && APP_PID="$(pgrep -f 'claudecodeirc' | head -1 || true)"
[[ -z "$APP_PID" ]] && smoke_die "no claudecodeirc pid found"
echo "  pid=$APP_PID"

echo
echo "=== phase 4: sample profiler 4s while typing 30 chars ==="
SAMPLE_FILE="$ARTIFACTS/sample.txt"
sample "$APP_PID" 4 -file "$SAMPLE_FILE" >/dev/null 2>&1 &
SAMPLE_PID=$!
# Type 30 chars at 50ms cadence — same load shape as the user's repro.
for c in a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4; do
    tmux send-keys -t "$SMOKE_SESSION:0.0" "$c"
    sleep 0.05
done
wait "$SAMPLE_PID" || true
echo "  sample saved to $SAMPLE_FILE"

echo
echo "=== phase 5: assert FileLogHandler is NOT a hot stack ==="
# `sample` output puts call-tree counts at the start of each frame
# line. The top-25 frames are where wall-time concentrates.
TOP_OUTPUT="$(grep -E "^[[:space:]]+[0-9]+ " "$SAMPLE_FILE" 2>/dev/null | head -50 || true)"
[[ -z "$TOP_OUTPUT" ]] && TOP_OUTPUT="$(cat "$SAMPLE_FILE")"

if grep -q "FileLogHandler.log" <<<"$TOP_OUTPUT"; then
    echo "  FAIL  FileLogHandler.log appears in sample top stacks — perf regression"
    echo "        full sample: $SAMPLE_FILE"
    SMOKE_FAILED=1
else
    echo "  PASS  FileLogHandler.log NOT in sample top stacks (compile-time gate working)"
fi

# Also check no claude-driver hot stacks appear (those would mean the
# build is wired wrong somehow and is logging via OSLog into the file).
if grep -q "FileLogHandler.debug" <<<"$TOP_OUTPUT"; then
    echo "  FAIL  FileLogHandler.debug appears in sample top stacks"
    SMOKE_FAILED=1
else
    echo "  PASS  FileLogHandler.debug NOT in sample top stacks"
fi

echo
echo "=== phase 6: report sample size (sanity) ==="
TOTAL="$(grep -m1 "Total number of samples" "$SAMPLE_FILE" 2>/dev/null || echo "n/a")"
echo "  $TOTAL"

echo
smoke_finish

#!/usr/bin/env bash
# tmux-e2e-3p.sh — 3-pane variant of tmux-e2e.sh. Spins up alice
# (host), bob (peer), charlie (peer) in a single tmux session. Each
# pane runs its own ccirc with an isolated CCIRC_DATA_DIR.
#
# Usage:
#   scripts/tmux-e2e-3p.sh             # teardown prior state + start + attach
#   scripts/tmux-e2e-3p.sh no-attach   # same but don't attach
#   scripts/tmux-e2e-3p.sh teardown    # kill processes + session, wipe dirs
#
# Drive the UI from inside tmux:
#   pane 0 (alice):   /nick alice → /host → Enter
#   pane 1 (bob):     /nick bob → Tab → Down → Enter (joins alice's LAN row)
#   pane 2 (charlie): /nick charlie → Tab → Down → Enter

set -euo pipefail

SESSION="ccirc-e2e-3p"
ALICE_DIR="${TMPDIR:-/tmp}/ccirc-3p-alice"
BOB_DIR="${TMPDIR:-/tmp}/ccirc-3p-bob"
CHARLIE_DIR="${TMPDIR:-/tmp}/ccirc-3p-charlie"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_DIR/.build/debug/claudecodeirc"

teardown() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    pkill -9 -f 'claudecodeirc' 2>/dev/null || true
    rm -rf "$ALICE_DIR" "$BOB_DIR" "$CHARLIE_DIR"
    echo "torn down: session '$SESSION', ccirc processes, data dirs"
}

cmd="${1:-setup}"

case "$cmd" in
    teardown) teardown; exit 0 ;;
    setup|no-attach) ;;
    *) echo "unknown command: $cmd (expected setup | no-attach | teardown)" >&2; exit 2 ;;
esac

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is not installed — install it first (brew install tmux)" >&2
    exit 1
fi

if [[ ! -x "$BIN" ]]; then
    echo "binary not found at $BIN" >&2
    echo "build first:  swift build" >&2
    exit 1
fi

teardown

mkdir -p "$ALICE_DIR" "$BOB_DIR" "$CHARLIE_DIR"

# 270x60 → three side-by-side panes at 90x60 each. Each ccirc layout
# needs ≥ ~80 cols for the 3-column workspace to render without
# truncation; 90 leaves a little slack.
tmux new-session -d -s "$SESSION" -x 270 -y 60
tmux split-window -h -t "$SESSION:0.0"
tmux split-window -h -t "$SESSION:0.1"
tmux select-layout -t "$SESSION:0" even-horizontal

tmux send-keys -t "$SESSION:0.0" \
    "CCIRC_DATA_DIR='$ALICE_DIR' '$BIN'" C-m
tmux send-keys -t "$SESSION:0.1" \
    "CCIRC_DATA_DIR='$BOB_DIR' '$BIN'" C-m
tmux send-keys -t "$SESSION:0.2" \
    "CCIRC_DATA_DIR='$CHARLIE_DIR' '$BIN'" C-m

echo "session '$SESSION' ready:"
echo "  pane 0 — alice   ($ALICE_DIR)"
echo "  pane 1 — bob     ($BOB_DIR)"
echo "  pane 2 — charlie ($CHARLIE_DIR)"
echo
echo "attach:    tmux attach-session -t $SESSION"
echo "teardown:  $0 teardown"

if [[ "$cmd" == "setup" ]]; then
    exec tmux attach-session -t "$SESSION"
fi

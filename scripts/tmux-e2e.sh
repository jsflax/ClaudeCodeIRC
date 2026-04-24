#!/usr/bin/env bash
# tmux-e2e.sh — spin up two isolated ccirc instances in a single tmux
# session for local end-to-end testing. Each pane runs the app with
# its own CCIRC_DATA_DIR, so prefs + room storage are fully isolated
# — the two instances behave like genuinely different users on
# different machines, discovering each other via Bonjour over loopback.
#
# Usage:
#   scripts/tmux-e2e.sh             # teardown prior state + start + attach
#   scripts/tmux-e2e.sh no-attach   # same but don't attach (headless)
#   scripts/tmux-e2e.sh teardown    # kill processes + session, wipe dirs
#
# Drive the UI from inside tmux:
#   pane 0 (alice): /nick alice → press `/` to see the popup, pick /host
#   pane 1 (bob):   /nick bob   → arrow over to alice's discovered row,
#                                  press Enter to join

set -euo pipefail

SESSION="ccirc-e2e"
ALICE_DIR="${TMPDIR:-/tmp}/ccirc-alice"
BOB_DIR="${TMPDIR:-/tmp}/ccirc-bob"

# Resolve binary relative to this script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_DIR/.build/debug/claudecodeirc"

teardown() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    pkill -9 -f 'claudecodeirc' 2>/dev/null || true
    rm -rf "$ALICE_DIR" "$BOB_DIR"
    echo "torn down: session '$SESSION', ccirc processes, $ALICE_DIR, $BOB_DIR"
}

cmd="${1:-setup}"

case "$cmd" in
    teardown)
        teardown
        exit 0
        ;;
    setup|no-attach)
        ;;
    *)
        echo "unknown command: $cmd (expected setup | no-attach | teardown)" >&2
        exit 2
        ;;
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

# Fresh slate — preserving state across runs leads to misleading bugs
# (peer discovers a dead host from last run, etc.).
teardown

mkdir -p "$ALICE_DIR" "$BOB_DIR"

# Wide layout — 240x60 fits two side-by-side 3-column workspaces
# without cramping. Resize interactively after attaching if needed.
tmux new-session -d -s "$SESSION" -x 240 -y 60
tmux split-window -h -t "$SESSION:0.0"

# Launch one ccirc per pane, each scoped to its own data dir. The
# env var is set inline so it lasts only for this invocation — re-
# running the pane without the prefix would use the default path.
tmux send-keys -t "$SESSION:0.0" \
    "CCIRC_DATA_DIR='$ALICE_DIR' '$BIN'" C-m
tmux send-keys -t "$SESSION:0.1" \
    "CCIRC_DATA_DIR='$BOB_DIR' '$BIN'" C-m

echo "session '$SESSION' ready:"
echo "  pane 0 — alice (data dir: $ALICE_DIR)"
echo "  pane 1 — bob   (data dir: $BOB_DIR)"
echo
echo "attach:    tmux attach-session -t $SESSION"
echo "teardown:  $0 teardown"

if [[ "$cmd" == "setup" ]]; then
    exec tmux attach-session -t "$SESSION"
fi

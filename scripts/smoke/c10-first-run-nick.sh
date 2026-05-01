#!/usr/bin/env bash
# First-run nick picker smoke. Fresh data dir → overlay should appear.
# Submitting a valid nick dismisses it. Subsequent launch from the
# same data dir should NOT show the overlay.
set -uo pipefail
SCRIPT_DIR="/Users/jason.flax/Projects/ClaudeCodeIRC/ClaudeCodeIRC/scripts/smoke"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "first-run-nick"
ART="/tmp/ccirc-first-run-nick"
mkdir -p "$ART"

echo "=== phase 1: launch alice with empty data dir ==="
tmux new-session -d -s "$SMOKE_SESSION" -x 240 -y 60
tmux send-keys -t "$SMOKE_SESSION:0.0" "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN'" C-m
sleep 4

echo
echo "=== phase 2: confirm overlay is showing ==="
CAP="$(capture_pane 0)"
capture_pane_to 0 "$ART/before-submit.txt"
assert_contains "Welcome banner visible" "Welcome to ClaudeCodeIRC" "$CAP"
assert_contains "nick prompt visible" "Pick a nickname" "$CAP"
assert_contains "submit hint visible" "↵ continue" "$CAP"

echo
echo "=== phase 3: type valid nick + submit ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" "alice"
sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter
sleep 1.5
CAP="$(capture_pane 0)"
capture_pane_to 0 "$ART/after-submit.txt"
assert_not_contains "Welcome banner gone after submit" "Welcome to ClaudeCodeIRC" "$CAP"
# Top-bar should now show the nick.
assert_contains "top-bar shows <alice>" "<alice>" "$CAP"

echo
echo "=== phase 4: relaunch from same data dir — overlay should NOT appear ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" C-c
sleep 1
pkill -9 -f 'claudecodeirc' 2>/dev/null || true
sleep 1
tmux send-keys -t "$SMOKE_SESSION:0.0" "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN'" C-m
sleep 4
CAP="$(capture_pane 0)"
capture_pane_to 0 "$ART/relaunch.txt"
assert_not_contains "Welcome banner does NOT show on relaunch" "Welcome to ClaudeCodeIRC" "$CAP"
assert_contains "top-bar shows <alice> on relaunch" "<alice>" "$CAP"

echo
echo "=== phase 5: validation — empty nick rejected, whitespace rejected ==="
# Wipe and start fresh.
pkill -9 -f 'claudecodeirc' 2>/dev/null || true
sleep 1
rm -rf "$ALICE_DIR"
mkdir -p "$ALICE_DIR"
tmux send-keys -t "$SMOKE_SESSION:0.0" "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN'" C-m
sleep 4

# Empty submit: just hit Enter with no input.
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter
sleep 0.5
CAP="$(capture_pane 0)"
assert_contains "empty nick error shown" "can't be empty" "$CAP"
assert_contains "overlay still visible after empty submit" "Pick a nickname" "$CAP"

# Whitespace nick: type "alice bob" + Enter
tmux send-keys -t "$SMOKE_SESSION:0.0" "alice bob"
sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter
sleep 0.5
CAP="$(capture_pane 0)"
assert_contains "whitespace nick error shown" "can't contain whitespace" "$CAP"
assert_contains "overlay still visible after whitespace submit" "Pick a nickname" "$CAP"

smoke_finish

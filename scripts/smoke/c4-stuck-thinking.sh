#!/usr/bin/env bash
# C4 — Stuck-thinking on Ctrl+C rejoin (regression-guard).
#
# When the host process is killed mid-AskUserQuestion (e.g. Ctrl+C
# during streaming), the Turn is left .streaming, the AskQuestion
# rows are left .pending, and on relaunch the UI would render a
# permanent "thinking" indicator with a ballot whose votes can't
# route back anywhere. The fix is in
# `RoomsModel.terminateOrphanedInFlightRows` (called from
# `reopenAsHost`) which flips Turn → .errored, AskQuestion →
# .cancelled, ToolEvent → .errored, ApprovalRequest → .denied
# inside a single transaction.
#
# Solo case (alice only) — the cleanup is host-side; peers don't
# do anything special on rejoin.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c4"

ARTIFACTS="/tmp/ccirc-smoke-c4"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn alice solo ==="
setup_solo
host_session 0 alice "$SMOKE_ROOM_NAME"
ALICE_LATTICE="$(wait_for_lattice "$ALICE_DIR" 20 || true)"
[[ -z "$ALICE_LATTICE" ]] && smoke_die "no alice lattice after host"
ROOM_CODE="$(basename "$ALICE_LATTICE" .lattice)"
echo "  room code: $ROOM_CODE"

echo
echo "=== phase 2: trigger AskUserQuestion ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude use AskUserQuestion to ask 'Pick a color' (single-select; options Red, Green, Blue, Purple). Output nothing else." Enter

wait_for_ask_count "$ALICE_LATTICE" 1 180 || smoke_die "AskQuestion never materialised"
echo "  AskQuestion appeared"

PRE_PENDING="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM AskQuestion WHERE status='pending';")"
PRE_STREAMING="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM Turn WHERE status='streaming';")"
echo "  pre-kill: pending Asks=$PRE_PENDING, streaming Turns=$PRE_STREAMING"
assert_ge "Q is pending pre-kill" 1 "$PRE_PENDING"
assert_ge "Turn is streaming pre-kill" 1 "$PRE_STREAMING"

echo
echo "=== phase 3: hard-kill alice (simulates Ctrl+C / crash) ==="
pkill -9 -f 'claudecodeirc' 2>/dev/null || true
pkill -9 -f 'claude -p' 2>/dev/null || true
sleep 2
tmux kill-session -t "$SMOKE_SESSION" 2>/dev/null || true

POST_KILL_PENDING="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM AskQuestion WHERE status='pending';")"
POST_KILL_STREAMING="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM Turn WHERE status='streaming';")"
echo "  post-kill: pending Asks=$POST_KILL_PENDING, streaming Turns=$POST_KILL_STREAMING"
# The orphan rows are still pending/streaming on disk — the kill
# skipped any cleanup. The fix runs on REOPEN, not on shutdown.

echo
echo "=== phase 4: relaunch alice and reopen the room ==="
tmux new-session -d -s "$SMOKE_SESSION" -x 240 -y 60
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN'" C-m
sleep 4
tmux send-keys -t "$SMOKE_SESSION:0.0" "/reopen $ROOM_CODE" Enter
sleep 6

echo
echo "=== phase 5: assert orphan rows are cleaned ==="
POST_REOPEN_PENDING="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM AskQuestion WHERE status='pending';")"
POST_REOPEN_STREAMING="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM Turn WHERE status='streaming';")"
POST_REOPEN_CANCELLED="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM AskQuestion WHERE status='cancelled';")"
POST_REOPEN_ERRORED="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM Turn WHERE status='errored';")"

assert_eq "no AskQuestion left .pending after reopen" 0 "$POST_REOPEN_PENDING"
assert_eq "no Turn left .streaming after reopen"      0 "$POST_REOPEN_STREAMING"
assert_ge "AskQuestion moved to .cancelled" 1 "$POST_REOPEN_CANCELLED"
assert_ge "Turn moved to .errored"          1 "$POST_REOPEN_ERRORED"

# UI-side: the thinking strip should be gone, and the cancelled
# ballot should display its `✗ cancelled` footer instead of any
# live ballot affordances.
#
# The question text ("Pick a color") survives in scrollback as part
# of the cancelled card — that's correct; we don't expunge history.
# What we DO assert: the cancelled footer is rendered (proves the
# orphan cleanup propagated through the UI) and there's no
# "thinking" indicator from the dead Turn.
ALICE_CAP="$(capture_pane 0)"
capture_pane_to 0 "$ARTIFACTS/alice-after-reopen.txt"
assert_contains "cancelled footer rendered" "✗ cancelled" "$ALICE_CAP"
assert_not_contains "no live thinking indicator" "thinking" "$ALICE_CAP"

echo
smoke_finish

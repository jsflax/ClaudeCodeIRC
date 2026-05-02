#!/usr/bin/env bash
# C15 — terminal bell on inbound message in a non-active room.
#
# bob hosts a SECOND room after joining alice's, making the second
# room his active. alice then sends a message into the first room.
# bob's stderr should receive a BEL byte (0x07), since the message
# landed in his non-active room.
#
# To verify the bell, the panes redirect stderr to a per-user log
# file (the default `setup_3p` doesn't), then we grep the log for
# the BEL byte.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c15"

ARTIFACTS="/tmp/ccirc-smoke-c15"
mkdir -p "$ARTIFACTS"
ALICE_STDERR="$ARTIFACTS/alice.stderr"
BOB_STDERR="$ARTIFACTS/bob.stderr"
: > "$ALICE_STDERR"
: > "$BOB_STDERR"

echo "=== phase 1: 2-pane setup with stderr redirected ==="
# Custom 2-pane spawn — same shape as setup_3p but only 2 panes and
# each pane's stderr is captured to a file so we can grep for BEL.
tmux new-session -d -s "$SMOKE_SESSION" -x 270 -y 60
tmux split-window -h -t "$SMOKE_SESSION:0.0"
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN' 2>'$ALICE_STDERR'" C-m
tmux send-keys -t "$SMOKE_SESSION:0.1" \
    "CCIRC_DATA_DIR='$BOB_DIR' '$SMOKE_BIN' 2>'$BOB_STDERR'" C-m
sleep 4

echo
echo "=== phase 2: alice hosts a-room, bob joins it ==="
ROOM_A="${SMOKE_NAME}-a-${SMOKE_ROOM_SUFFIX}"
ROOM_B="${SMOKE_NAME}-b-${SMOKE_ROOM_SUFFIX}"
host_session 0 alice "$ROOM_A"
join_session 1 bob "$ROOM_A"

ALICE_LATTICE="$(wait_for_lattice "$ALICE_DIR" 20 || true)"
BOB_LATTICE="$(wait_for_lattice "$BOB_DIR" 20 || true)"
[[ -z "$ALICE_LATTICE" ]] && smoke_die "no alice lattice"
[[ -z "$BOB_LATTICE"   ]] && smoke_die "no bob lattice"

wait_for_member_count "$ALICE_LATTICE" 2 30 || smoke_die "alice never saw 2 members in a-room"
wait_for_member_count "$BOB_LATTICE"   2 30 || smoke_die "bob never saw 2 members in a-room"

echo
echo "=== phase 3: bob hosts b-room → b-room becomes bob's active ==="
# After joining a-room, bob is "in" it. /host pops the form, then
# Tab/Space/Enter to commit a private room (same key model as
# host_session). The host() flow appends b-room and flips
# activeRoomId to b-room.
tmux send-keys -t "$SMOKE_SESSION:0.1" "/host" Enter
sleep 2
tmux send-keys -t "$SMOKE_SESSION:0.1" "$ROOM_B"
sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.1" Tab; sleep 0.1
tmux send-keys -t "$SMOKE_SESSION:0.1" Tab; sleep 0.1
tmux send-keys -t "$SMOKE_SESSION:0.1" Tab; sleep 0.1
tmux send-keys -t "$SMOKE_SESSION:0.1" Space  # public → private
sleep 0.2
tmux send-keys -t "$SMOKE_SESSION:0.1" Enter
sleep 4

# Capture bob's pane to confirm b-room is active. The status line's
# `[<roomname>]` shows the active room — after host() it should be
# b-room.
BOB_AFTER_HOST="$(capture_pane 1)"
capture_pane_to 1 "$ARTIFACTS/bob-after-host.txt"
assert_contains "bob's active room is b-room" "[$ROOM_B]" "$BOB_AFTER_HOST"

# Truncate bob's stderr AFTER all setup completes — any stray BELs
# produced during the host flow shouldn't count toward the assertion.
: > "$BOB_STDERR"

echo
echo "=== phase 4: alice sends a message in a-room → bob should bell ==="
BELL_MSG="ring-the-bell-c15"
tmux send-keys -t "$SMOKE_SESSION:0.0" "$BELL_MSG" Enter
# Give the WS sync + observer dispatch time to land. Empirically a
# round-trip + observer fire is well under 1s on loopback.
sleep 2

# Grep for BEL byte (0x07) in bob's stderr capture.
BELL_COUNT="$(LC_ALL=C tr -cd '\007' < "$BOB_STDERR" | wc -c | tr -d ' ')"
echo "  bob.stderr BEL byte count = $BELL_COUNT"
assert_ge "bob received at least 1 BEL byte" 1 "$BELL_COUNT"

echo
echo "=== phase 5: bob switches to a-room → message there is silent ==="
# Ctrl+P cycles back to a-room (bob's other joined room).
tmux send-keys -t "$SMOKE_SESSION:0.1" C-p
sleep 1
: > "$BOB_STDERR"

# alice sends another message; this one should NOT bell because
# a-room is now bob's active room.
SILENT_MSG="silent-c15"
tmux send-keys -t "$SMOKE_SESSION:0.0" "$SILENT_MSG" Enter
sleep 2

SILENT_BELL_COUNT="$(LC_ALL=C tr -cd '\007' < "$BOB_STDERR" | wc -c | tr -d ' ')"
echo "  bob.stderr BEL byte count (active room) = $SILENT_BELL_COUNT"
assert_eq "active room is silent" 0 "$SILENT_BELL_COUNT"

echo
smoke_finish

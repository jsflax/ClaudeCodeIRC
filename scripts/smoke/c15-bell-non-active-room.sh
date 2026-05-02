#!/usr/bin/env bash
# C15 — terminal bell on any inbound non-self message.
#
# `RoomsModel.wireBell` fires unconditionally for foreign user/action
# messages (no active-room gate) — alice's send into a-room should
# bell bob's terminal both when he's on b-room and when he's on
# a-room itself.
#
# Verification: each ring writes a `bell ring` Log line. We grep the
# shared ccirc.log for it. Direct BEL-byte capture isn't reliable
# because beep() goes through the curses output buffer, not stderr.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c15"

ARTIFACTS="/tmp/ccirc-smoke-c15"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: 2-pane setup ==="
tmux new-session -d -s "$SMOKE_SESSION" -x 270 -y 60
tmux split-window -h -t "$SMOKE_SESSION:0.0"
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN'" C-m
tmux send-keys -t "$SMOKE_SESSION:0.1" \
    "CCIRC_DATA_DIR='$BOB_DIR' '$SMOKE_BIN'" C-m
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

# Snapshot the log line count so we can scope subsequent assertions
# to *new* bell rings only — the host flow may produce its own bells
# if any pre-existing rooms trip the foreign-message hook.
LOG_BASELINE="$( { grep "\[bell\] ring" "$SMOKE_LOG" 2>/dev/null || true; } | wc -l | tr -d ' ')"
echo "  log baseline 'bell ring' count = $LOG_BASELINE"

echo
echo "=== phase 4: alice sends a message in a-room → bob should bell ==="
BELL_MSG="ring-the-bell-c15"
tmux send-keys -t "$SMOKE_SESSION:0.0" "$BELL_MSG" Enter
# Give the WS sync + observer dispatch time to land. Empirically a
# round-trip + observer fire is well under 1s on loopback.
sleep 2

LOG_AFTER="$( { grep "\[bell\] ring" "$SMOKE_LOG" 2>/dev/null || true; } | wc -l | tr -d ' ')"
NEW_RINGS=$(( LOG_AFTER - LOG_BASELINE ))
echo "  new 'bell ring' log entries = $NEW_RINGS"
assert_ge "bell rang for non-active room" 1 "$NEW_RINGS"

echo
echo "=== phase 5: bob switches to a-room → bell still fires (no gate) ==="
# Ctrl+P cycles back to a-room (bob's other joined room).
tmux send-keys -t "$SMOKE_SESSION:0.1" C-p
sleep 1
LOG_BASELINE_2="$( { grep "\[bell\] ring" "$SMOKE_LOG" 2>/dev/null || true; } | wc -l | tr -d ' ')"

# alice sends another message; with the active-room gate dropped
# this should ALSO bell — bell fires for any non-self message.
ACTIVE_MSG="active-c15"
tmux send-keys -t "$SMOKE_SESSION:0.0" "$ACTIVE_MSG" Enter
sleep 2

LOG_AFTER_2="$( { grep "\[bell\] ring" "$SMOKE_LOG" 2>/dev/null || true; } | wc -l | tr -d ' ')"
ACTIVE_RINGS=$(( LOG_AFTER_2 - LOG_BASELINE_2 ))
echo "  new 'bell ring' log entries while active = $ACTIVE_RINGS"
assert_ge "bell rings even in active room" 1 "$ACTIVE_RINGS"

echo
smoke_finish

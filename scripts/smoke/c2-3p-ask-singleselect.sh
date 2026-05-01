#!/usr/bin/env bash
# C2 — 3-peer single-select Ask, 2/3 majority.
#
# Locks in the n=3 majority rule from `AskTally.swift:31–43`
# (`singleSelectFirstToThresholdWins`): for `presentQuorum=3` →
# threshold=2. Two voters pick the same option; the third picks a
# different one; the question resolves on the majority pick.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c2"

ARTIFACTS="/tmp/ccirc-smoke-c2"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn 3-pane ==="
setup_3p
host_session 0 alice "$SMOKE_ROOM_NAME"
join_session 1 bob "$SMOKE_ROOM_NAME"
join_session 2 charlie "$SMOKE_ROOM_NAME"

resolve_lattices
[[ -z "$ALICE_LATTICE"   ]] && smoke_die "no alice lattice"
[[ -z "$BOB_LATTICE"     ]] && smoke_die "no bob lattice"
[[ -z "$CHARLIE_LATTICE" ]] && smoke_die "no charlie lattice"
wait_for_member_count "$ALICE_LATTICE"   3 30 || smoke_die "alice never saw 3 members"
wait_for_member_count "$BOB_LATTICE"     3 30 || smoke_die "bob never saw 3 members"
wait_for_member_count "$CHARLIE_LATTICE" 3 30 || smoke_die "charlie never saw 3 members"

echo
echo "=== phase 2: alice triggers a single-select Ask ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude use AskUserQuestion to ask 'Pick a color' (single-select; options Red, Green, Blue, Purple). Output nothing else." Enter

wait_for_ask_count "$ALICE_LATTICE" 1 180 || smoke_die "AskQuestion never materialised"
sleep 3   # let it sync to bob & charlie
echo "  question is live on all 3 panes"

echo
echo "=== phase 3: alice + bob vote Down+Enter (option 1 = Green); charlie votes Enter (option 0 = Red) ==="
# Vote sequence:
#   alice:   Down → option 1 (Green); Enter to commit single-select.
#   bob:     Down → option 1 (Green); Enter to commit.
#   charlie: stay on row 0 (Red); Enter to commit.
# Result: Green = 2 votes, Red = 1 vote → Green wins (2/3 majority).
tmux send-keys -t "$SMOKE_SESSION:0.0" Down; sleep 0.2
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter; sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.1" Down; sleep 0.2
tmux send-keys -t "$SMOKE_SESSION:0.1" Enter; sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.2" Enter

# Wait up to 5s for status to flip on alice's lattice.
wait_for_ask_status "$ALICE_LATTICE" answered 1 5 || smoke_die "Q never reached .answered"
echo "  Q answered"

echo
echo "=== phase 4: assert majority on every replica ==="
for label in alice bob charlie; do
    case "$label" in
        alice)   LAT="$ALICE_LATTICE" ;;
        bob)     LAT="$BOB_LATTICE" ;;
        charlie) LAT="$CHARLIE_LATTICE" ;;
    esac
    STATUS="$("$SMOKE_SQLITE" "$LAT" "SELECT status FROM AskQuestion;" 2>/dev/null || echo unknown)"
    CHOSEN="$("$SMOKE_SQLITE" "$LAT" "SELECT chosenLabels FROM AskQuestion;" 2>/dev/null || echo "")"
    assert_eq "$label: status .answered" "answered" "$STATUS"
    assert_contains "$label: chosen contains 'Green' (2/3 majority)" "Green" "$CHOSEN"
done

# UI sanity — all three panes show the answered footer.
for pane in 0 1 2; do
    CAP="$(capture_pane "$pane")"
    capture_pane_to "$pane" "$ARTIFACTS/pane-$pane.txt"
    assert_contains "pane $pane shows answered footer" "answered" "$CAP"
done

echo
smoke_finish

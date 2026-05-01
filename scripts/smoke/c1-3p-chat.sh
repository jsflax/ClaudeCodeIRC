#!/usr/bin/env bash
# C1 — 3-peer LAN host/join + bidirectional chat baseline.
#
# Gates that RoomSyncServer's broadcast path actually fans out to N
# concurrent peers. Alice hosts, bob & charlie join via the discovered
# LAN sidebar row, all three send messages, and we verify each peer
# sees all three lines.
#
# This is the foundation case for the smoke suite — every other 3-peer
# case (C2/C5/C6/C7/C8) depends on the harness in here working.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c1"

ARTIFACTS="/tmp/ccirc-smoke-c1"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn 3-pane (alice host + bob + charlie peers) ==="
setup_3p
host_session 0 alice "$SMOKE_ROOM_NAME"
join_session 1 bob "$SMOKE_ROOM_NAME"
join_session 2 charlie "$SMOKE_ROOM_NAME"

resolve_lattices
[[ -z "$ALICE_LATTICE"   ]] && { echo "FAIL: no alice lattice"; smoke_finish; exit 1; }
[[ -z "$BOB_LATTICE"     ]] && { echo "FAIL: no bob lattice"; smoke_finish; exit 1; }
[[ -z "$CHARLIE_LATTICE" ]] && { echo "FAIL: no charlie lattice"; smoke_finish; exit 1; }
echo "  alice:   $ALICE_LATTICE"
echo "  bob:     $BOB_LATTICE"
echo "  charlie: $CHARLIE_LATTICE"

echo
echo "=== phase 2: wait for all 3 Member rows to sync ==="
wait_for_member_count "$ALICE_LATTICE"   3 30 || { echo "FAIL: alice never saw 3 members"; smoke_finish; exit 1; }
wait_for_member_count "$BOB_LATTICE"     3 30 || { echo "FAIL: bob never saw 3 members"; smoke_finish; exit 1; }
wait_for_member_count "$CHARLIE_LATTICE" 3 30 || { echo "FAIL: charlie never saw 3 members"; smoke_finish; exit 1; }
echo "  all 3 peers see 3 Member rows"

echo
echo "=== phase 3: each peer sends a unique message ==="
ALICE_MSG="hello-from-alice-c1"
BOB_MSG="hello-from-bob-c1"
CHARLIE_MSG="hello-from-charlie-c1"

tmux send-keys -t "$SMOKE_SESSION:0.0" "$ALICE_MSG" Enter
sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.1" "$BOB_MSG" Enter
sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.2" "$CHARLIE_MSG" Enter
sleep 3   # let everything sync

echo
echo "=== phase 4: assert ChatMessage rows on every replica ==="
ALICE_MSGS="$("$SMOKE_SQLITE" "$ALICE_LATTICE"   "SELECT COUNT(*) FROM ChatMessage WHERE text LIKE '%-c1';")"
BOB_MSGS="$("$SMOKE_SQLITE" "$BOB_LATTICE"       "SELECT COUNT(*) FROM ChatMessage WHERE text LIKE '%-c1';")"
CHARLIE_MSGS="$("$SMOKE_SQLITE" "$CHARLIE_LATTICE" "SELECT COUNT(*) FROM ChatMessage WHERE text LIKE '%-c1';")"

assert_eq "alice has 3 chat messages"   3 "$ALICE_MSGS"
assert_eq "bob has 3 chat messages"     3 "$BOB_MSGS"
assert_eq "charlie has 3 chat messages" 3 "$CHARLIE_MSGS"

echo
echo "=== phase 5: assert each pane RENDERS all three messages ==="
ALICE_CAP="$(capture_pane 0)"
BOB_CAP="$(capture_pane 1)"
CHARLIE_CAP="$(capture_pane 2)"

capture_pane_to 0 "$ARTIFACTS/alice.txt"
capture_pane_to 1 "$ARTIFACTS/bob.txt"
capture_pane_to 2 "$ARTIFACTS/charlie.txt"

assert_contains "alice sees alice's msg"     "$ALICE_MSG"   "$ALICE_CAP"
assert_contains "alice sees bob's msg"       "$BOB_MSG"     "$ALICE_CAP"
assert_contains "alice sees charlie's msg"   "$CHARLIE_MSG" "$ALICE_CAP"

assert_contains "bob sees alice's msg"       "$ALICE_MSG"   "$BOB_CAP"
assert_contains "bob sees bob's msg"         "$BOB_MSG"     "$BOB_CAP"
assert_contains "bob sees charlie's msg"     "$CHARLIE_MSG" "$BOB_CAP"

assert_contains "charlie sees alice's msg"   "$ALICE_MSG"   "$CHARLIE_CAP"
assert_contains "charlie sees bob's msg"     "$BOB_MSG"     "$CHARLIE_CAP"
assert_contains "charlie sees charlie's msg" "$CHARLIE_MSG" "$CHARLIE_CAP"

echo
smoke_finish

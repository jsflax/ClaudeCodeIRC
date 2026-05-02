#!/usr/bin/env bash
# C14 — typing indicator end-to-end.
#
# Bob types into the composer (without pressing Enter); alice's pane
# should render an ephemeral "<bob> typing" row driven by the Lattice-
# synced `Member.typingUntil` field. After bob stops, the row should
# disappear within ~3s.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c14"

ARTIFACTS="/tmp/ccirc-smoke-c14"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: 2-pane (alice host + bob peer), wait for sync ==="
setup_3p
host_session 0 alice "$SMOKE_ROOM_NAME"
join_session 1 bob "$SMOKE_ROOM_NAME"

resolve_lattices
[[ -z "$ALICE_LATTICE" ]] && smoke_die "no alice lattice"
[[ -z "$BOB_LATTICE"   ]] && smoke_die "no bob lattice"

wait_for_member_count "$ALICE_LATTICE" 2 30 || smoke_die "alice never saw 2 members"
wait_for_member_count "$BOB_LATTICE"   2 30 || smoke_die "bob never saw 2 members"

echo
echo "=== phase 2: bob types (no Enter) → alice should see typing row ==="
# Type a few characters one at a time to mimic real typing. The
# debouncer fires `selfMember.typingUntil = now + 3s` after a 250ms
# pause, so a single chunk + a brief sleep is enough to get one write
# in flight.
tmux send-keys -t "$SMOKE_SESSION:0.1" "hi alice"
sleep 1.5  # let debounce land + Lattice sync the Member update

# Check sqlite directly: bob's Member row in alice's lattice should
# have a non-null typingUntil > now.
BOB_TU="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT typingUntil FROM Member WHERE nick='bob';")"
echo "  alice's view of bob.typingUntil = '$BOB_TU'"
if [[ -z "$BOB_TU" || "$BOB_TU" == "0.0" ]]; then
    echo "  FAIL  bob.typingUntil should be set in alice's lattice"
    SMOKE_FAILED=1
else
    echo "  PASS  bob.typingUntil set in alice's lattice (=$BOB_TU)"
fi

ALICE_CAP_TYPING="$(capture_pane 0)"
capture_pane_to 0 "$ARTIFACTS/alice-typing.txt"
assert_contains "alice pane shows 'typing' row"     "typing"   "$ALICE_CAP_TYPING"
assert_contains "alice pane shows bob's nick on it" "<bob>"    "$ALICE_CAP_TYPING"

echo
echo "=== phase 3: bob clears the draft → typing row clears immediately ==="
# Backspace × 8 wipes "hi alice"; the .task(id: draft) hits the empty
# branch and writes typingUntil = nil.
for _ in 1 2 3 4 5 6 7 8; do
    tmux send-keys -t "$SMOKE_SESSION:0.1" BSpace
done
sleep 1.5  # let the nil write sync

BOB_TU_AFTER="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT IFNULL(typingUntil, 'NULL') FROM Member WHERE nick='bob';")"
assert_eq "bob.typingUntil cleared after empty draft" "NULL" "$BOB_TU_AFTER"

ALICE_CAP_CLEAR="$(capture_pane 0)"
capture_pane_to 0 "$ARTIFACTS/alice-cleared.txt"
# `typing` literal should be absent from alice's pane after the row
# vanishes. Note: this assertion would false-positive if any other
# message in the scrollback contained the word "typing"; the smoke
# harness sends only deterministic test messages so that's not a
# concern here.
assert_not_contains "alice pane no longer shows typing row" "typing" "$ALICE_CAP_CLEAR"

echo
echo "=== phase 4: bob types and sends → typing row replaced by message ==="
tmux send-keys -t "$SMOKE_SESSION:0.1" "hello-c14"
sleep 0.5  # ensure debouncer fires at least once
tmux send-keys -t "$SMOKE_SESSION:0.1" Enter
sleep 1.5  # let send + sync settle

BOB_TU_FINAL="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT IFNULL(typingUntil, 'NULL') FROM Member WHERE nick='bob';")"
assert_eq "bob.typingUntil cleared after send" "NULL" "$BOB_TU_FINAL"

ALICE_CAP_FINAL="$(capture_pane 0)"
capture_pane_to 0 "$ARTIFACTS/alice-final.txt"
assert_contains "alice sees bob's sent message" "hello-c14" "$ALICE_CAP_FINAL"
assert_not_contains "alice pane no longer shows typing row" "typing" "$ALICE_CAP_FINAL"

echo
smoke_finish

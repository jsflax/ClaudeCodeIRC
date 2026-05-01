#!/usr/bin/env bash
# C8 — Multi-select Ask wait-for-all (3 peers).
#
# Multi-select Asks resolve only after every present voter casts a
# ballot (`AskTally.swift:93` — `ballotCount >= presentQuorum`),
# then strict-majority filter picks labels with ≥ ⌈n/2⌉+1 votes.
#
# Plan: alice toggles A+B, bob toggles A+C, charlie toggles A only.
# Per option:
#   A: alice + bob + charlie = 3 → ≥ 2 → wins
#   B: alice only = 1 → < 2 → out
#   C: bob only = 1 → < 2 → out
# Final chosen labels = ["A"].
#
# Mid-test verification: between alice + bob committing and charlie
# committing, the question must remain .pending (the wait-for-all
# rule). Only after charlie commits does it flip to .answered.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c8"

ARTIFACTS="/tmp/ccirc-smoke-c8"
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
echo "=== phase 2: alice triggers a multi-select Ask ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude use AskUserQuestion to ask 'Pick categories' (multi-select; options A, B, C, D). Output nothing else." Enter

wait_for_ask_count "$ALICE_LATTICE" 1 180 || smoke_die "AskQuestion never materialised"
sleep 3

# Sanity — verify it really is multi-select.
MULTI="$("$SMOKE_SQLITE" "$ALICE_LATTICE" "SELECT multiSelect FROM AskQuestion;")"
assert_eq "question is multi-select" 1 "$MULTI"

echo
echo "=== phase 3: alice toggles A+B then commits with Space ==="
# Multi-select: Enter toggles a row, Space commits the local ballot.
# Start at row 0 (A): Enter (toggle A on), Down, Enter (toggle B on),
# Space (commit).
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter; sleep 0.2     # toggle A
tmux send-keys -t "$SMOKE_SESSION:0.0" Down;  sleep 0.2     # → row 1
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter; sleep 0.2     # toggle B
tmux send-keys -t "$SMOKE_SESSION:0.0" Space; sleep 1.5     # commit ballot

echo "=== phase 4: bob toggles A+C then commits ==="
tmux send-keys -t "$SMOKE_SESSION:0.1" Enter; sleep 0.2     # toggle A
tmux send-keys -t "$SMOKE_SESSION:0.1" Down;  sleep 0.2     # row 1
tmux send-keys -t "$SMOKE_SESSION:0.1" Down;  sleep 0.2     # row 2
tmux send-keys -t "$SMOKE_SESSION:0.1" Enter; sleep 0.2     # toggle C
tmux send-keys -t "$SMOKE_SESSION:0.1" Space; sleep 1.5     # commit

echo
echo "=== phase 5: assert question still .pending (charlie hasn't voted) ==="
sleep 1
MID_STATUS="$("$SMOKE_SQLITE" "$ALICE_LATTICE" "SELECT status FROM AskQuestion;")"
assert_eq "Q still pending after 2 of 3 ballots (multi-select wait-for-all)" \
    "pending" "$MID_STATUS"

echo
echo "=== phase 6: charlie toggles A only then commits ==="
tmux send-keys -t "$SMOKE_SESSION:0.2" Enter; sleep 0.2     # toggle A
tmux send-keys -t "$SMOKE_SESSION:0.2" Space; sleep 1.5     # commit

# Wait up to 5s for status to flip.
wait_for_ask_status "$ALICE_LATTICE" answered 1 5 || smoke_die "Q never reached .answered after all 3 ballots"

echo
echo "=== phase 7: assert chosenLabels = exactly 'A' ==="
for label in alice bob charlie; do
    case "$label" in
        alice)   LAT="$ALICE_LATTICE" ;;
        bob)     LAT="$BOB_LATTICE" ;;
        charlie) LAT="$CHARLIE_LATTICE" ;;
    esac
    CHOSEN="$("$SMOKE_SQLITE" "$LAT" "SELECT chosenLabels FROM AskQuestion;")"
    assert_contains "$label: chosen contains A (3 votes ≥ 2)" "A" "$CHOSEN"
    # Negative — B and C each got 1 vote → out.
    if grep -qE '"B"' <<<"$CHOSEN"; then
        echo "  FAIL  $label: B should not be in chosen (only 1 vote)"; SMOKE_FAILED=1
    else
        echo "  PASS  $label: B not in chosen (correctly excluded)"
    fi
    if grep -qE '"C"' <<<"$CHOSEN"; then
        echo "  FAIL  $label: C should not be in chosen (only 1 vote)"; SMOKE_FAILED=1
    else
        echo "  PASS  $label: C not in chosen (correctly excluded)"
    fi
done

echo
smoke_finish

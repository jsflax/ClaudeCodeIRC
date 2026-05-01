#!/usr/bin/env bash
# C6 — AskComment discussion thread sync (3 peers).
#
# All 3 peers post a discussion comment on the same pending Ask.
# Verify:
#   - 3 AskComment rows on every replica (Lattice sync correctness),
#   - all 3 nicks rendered in each pane's discussion section,
#   - none of the comment text leaks into claude (architectural
#     guarantee that comments stay peer-to-peer).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c6"

ARTIFACTS="/tmp/ccirc-smoke-c6"
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
echo "=== phase 2: alice triggers an Ask (single-select, simple) ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude use AskUserQuestion to ask 'Pick a color' (single-select; options Red, Green, Blue, Purple). Output nothing else." Enter

wait_for_ask_count "$ALICE_LATTICE" 1 180 || smoke_die "AskQuestion never materialised"
sleep 3
echo "  question live on all 3 panes"

# Sentinels — distinct text per peer so we can confirm exactly who
# wrote what synced everywhere.
ALICE_TEXT="alice-says-c6-red-is-loud"
BOB_TEXT="bob-says-c6-blue-is-calm"
CHARLIE_TEXT="charlie-says-c6-just-pick-one"

echo
echo "=== phase 3: alice posts a discussion comment ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" Tab; sleep 0.4
tmux send-keys -t "$SMOKE_SESSION:0.0" "$ALICE_TEXT"; sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.0" Enter; sleep 3

echo "=== phase 4: bob posts a discussion comment ==="
tmux send-keys -t "$SMOKE_SESSION:0.1" Tab; sleep 0.4
tmux send-keys -t "$SMOKE_SESSION:0.1" "$BOB_TEXT"; sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.1" Enter; sleep 3

echo "=== phase 5: charlie posts a discussion comment ==="
tmux send-keys -t "$SMOKE_SESSION:0.2" Tab; sleep 0.4
tmux send-keys -t "$SMOKE_SESSION:0.2" "$CHARLIE_TEXT"; sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.2" Enter; sleep 4

echo
echo "=== phase 6: assert all 3 AskComment rows synced everywhere ==="
for label in alice bob charlie; do
    case "$label" in
        alice)   LAT="$ALICE_LATTICE" ;;
        bob)     LAT="$BOB_LATTICE" ;;
        charlie) LAT="$CHARLIE_LATTICE" ;;
    esac
    N="$("$SMOKE_SQLITE" "$LAT" "SELECT COUNT(*) FROM AskComment;")"
    assert_eq "$label has 3 AskComment rows" 3 "$N"
done

echo
echo "=== phase 7: assert each pane RENDERS all 3 comments ==="
for pane in 0 1 2; do
    CAP="$(capture_pane "$pane")"
    capture_pane_to "$pane" "$ARTIFACTS/pane-$pane.txt"
    assert_contains "pane $pane shows alice's comment"   "$ALICE_TEXT"   "$CAP"
    assert_contains "pane $pane shows bob's comment"     "$BOB_TEXT"     "$CAP"
    assert_contains "pane $pane shows charlie's comment" "$CHARLIE_TEXT" "$CAP"
done

echo
echo "=== phase 8: claude must NOT have seen any of the comment text ==="
# The driver's stream-json output is mirrored into the lattice as
# AssistantChunks (claude's reasoning) + ToolEvent results
# (tool inputs/outputs). Comments live in the AskComment table and
# never get shipped to claude — verify by negative assertion against
# every claude-visible surface.
for label in alice; do
    LAT="$ALICE_LATTICE"
    AC="$("$SMOKE_SQLITE" "$LAT" "SELECT GROUP_CONCAT(text, '|') FROM AssistantChunk;" 2>/dev/null || echo "")"
    TE="$("$SMOKE_SQLITE" "$LAT" "SELECT GROUP_CONCAT(input, '|') || GROUP_CONCAT(result, '|') FROM ToolEvent;" 2>/dev/null || echo "")"
    HAY="$AC|$TE"
    assert_not_contains "claude did not see alice's comment"   "$ALICE_TEXT"   "$HAY"
    assert_not_contains "claude did not see bob's comment"     "$BOB_TEXT"     "$HAY"
    assert_not_contains "claude did not see charlie's comment" "$CHARLIE_TEXT" "$HAY"
done

echo
smoke_finish

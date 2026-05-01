#!/usr/bin/env bash
# C5 — Peer-ESC interrupt fanout (3 peers).
#
# Any peer pressing ESC during a streaming Turn must:
#   - flip Turn.cancelRequested = 1 in lattice (syncs to host),
#   - cause the host's CancelObserver to call driver.stop(),
#   - terminate the underlying `claude -p` subprocess,
#   - render `*** turn interrupted` on every pane (alice + bob + charlie).
#
# Memory `02856781` confirmed this end-to-end with 2 peers; this case
# extends it to 3 to gate the broadcast-fanout path on a real wire
# (RoomSyncServer.peers fan-out at scale).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c5"

ARTIFACTS="/tmp/ccirc-smoke-c5"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn 3-pane (alice host + bob + charlie) ==="
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
echo "=== phase 2: alice triggers a long claude turn ==="
# Long enough that bob has time to ESC before it finishes naturally.
# A "write a long python script" prompt typically streams for 20-40s.
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude write a 200-line python script implementing a basic linked list with insert, remove, find, and iter operations, plus a small test harness. Include detailed comments." Enter

# Wait for Turn to be in .streaming state.
for i in $(seq 1 30); do
    STREAMING="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT COUNT(*) FROM Turn WHERE status='streaming';" 2>/dev/null || echo 0)"
    [[ "${STREAMING:-0}" -ge 1 ]] && break
    sleep 1
done
[[ "${STREAMING:-0}" -lt 1 ]] && smoke_die "Turn never reached .streaming"
echo "  Turn streaming on alice"

# Confirm bob and charlie also see the streaming Turn.
sleep 2
BOB_STREAMING="$("$SMOKE_SQLITE" "$BOB_LATTICE" "SELECT COUNT(*) FROM Turn WHERE status='streaming';")"
CHARLIE_STREAMING="$("$SMOKE_SQLITE" "$CHARLIE_LATTICE" "SELECT COUNT(*) FROM Turn WHERE status='streaming';")"
assert_ge "bob sees streaming Turn"     1 "$BOB_STREAMING"
assert_ge "charlie sees streaming Turn" 1 "$CHARLIE_STREAMING"

echo
echo "=== phase 3: bob presses ESC ==="
tmux send-keys -t "$SMOKE_SESSION:0.1" Escape
ESC_AT="$(date +%s)"

# Wait up to 5s for cancelRequested to flip on alice's lattice.
for i in $(seq 1 25); do
    CANCEL_REQ="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT cancelRequested FROM Turn WHERE status='streaming' OR status='errored' OR status='done' ORDER BY startedAt DESC LIMIT 1;" 2>/dev/null || echo 0)"
    [[ "${CANCEL_REQ:-0}" == "1" ]] && break
    sleep 0.2
done
NOW="$(date +%s)"
PROP_LATENCY="$((NOW - ESC_AT))"
assert_eq "bob's ESC propagated cancelRequested=1 on alice" 1 "$CANCEL_REQ"
echo "  propagation latency: ${PROP_LATENCY}s"

echo
echo "=== phase 4: assert subprocess died + UI shows interrupt ==="
# Give the host's observer + driver.stop() a moment.
sleep 3

# `pgrep -cf` counts matches; exits 1 when zero — `|| echo 0` keeps
# the script from aborting under `set -e` / `set -o pipefail`.
CLAUDE_PROCS="$(pgrep -cf 'claude -p' 2>/dev/null || echo 0)"
assert_eq "no claude -p subprocess alive" 0 "$CLAUDE_PROCS"

ALICE_CAP="$(capture_pane 0)"
BOB_CAP="$(capture_pane 1)"
CHARLIE_CAP="$(capture_pane 2)"
capture_pane_to 0 "$ARTIFACTS/alice.txt"
capture_pane_to 1 "$ARTIFACTS/bob.txt"
capture_pane_to 2 "$ARTIFACTS/charlie.txt"

assert_contains "alice sees turn-interrupted notice"   "turn interrupted" "$ALICE_CAP"
assert_contains "bob sees turn-interrupted notice"     "turn interrupted" "$BOB_CAP"
assert_contains "charlie sees turn-interrupted notice" "turn interrupted" "$CHARLIE_CAP"

echo
smoke_finish

#!/usr/bin/env bash
# C7 — Tool approval Y/A/D quorum (3 peers).
#
# Claude requests a Bash tool — host's permission policy puts it
# in approval state. Voters split 2 yes / 1 deny → approved
# (presentQuorum=3 → strict-majority threshold = 2).
#
# Locks in `ApprovalTally.swift:44–62` for n=3 in a real-process
# harness; unit tests cover the math but never spin up an actual
# `claude -p` + shim subprocess tree.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c7"

ARTIFACTS="/tmp/ccirc-smoke-c7"
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
echo "=== phase 2: alice asks claude to use Write (requires approval) ==="
# `Write` always triggers approval under the default permission mode.
# (Bash with safe commands like `echo` is auto-allowed by claude's
# built-in allowlist, so it doesn't generate an ApprovalRequest.)
SENTINEL="c7-write-output-sentinel-$$"
TARGET="/tmp/ccirc-smoke-c7-write-target.txt"
rm -f "$TARGET"
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude please use the Write tool to create the file $TARGET with the exact contents \"$SENTINEL\". Only do that, nothing else." Enter

# Wait for the ApprovalRequest to appear.
for i in $(seq 1 90); do
    N="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT COUNT(*) FROM ApprovalRequest WHERE status='pending';" 2>/dev/null || echo 0)"
    [[ "${N:-0}" -ge 1 ]] && break
    sleep 1
done
[[ "${N:-0}" -lt 1 ]] && smoke_die "ApprovalRequest never appeared"
echo "  approval request live"

# Wait for it to sync to bob & charlie.
sleep 2
BOB_PEND="$("$SMOKE_SQLITE" "$BOB_LATTICE"     "SELECT COUNT(*) FROM ApprovalRequest WHERE status='pending';")"
CHARLIE_PEND="$("$SMOKE_SQLITE" "$CHARLIE_LATTICE" "SELECT COUNT(*) FROM ApprovalRequest WHERE status='pending';")"
assert_ge "bob sees pending approval"     1 "$BOB_PEND"
assert_ge "charlie sees pending approval" 1 "$CHARLIE_PEND"

echo
echo "=== phase 3: alice Y, bob Y, charlie D (2/3 → approved) ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" "y"; sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.1" "y"; sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.2" "d"

# Wait up to 5s for status flip.
for i in $(seq 1 25); do
    STATUS="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT status FROM ApprovalRequest ORDER BY requestedAt DESC LIMIT 1;" 2>/dev/null || echo unknown)"
    [[ "$STATUS" == "approved" || "$STATUS" == "denied" ]] && break
    sleep 0.2
done

assert_eq "approval resolved to .approved" "approved" "$STATUS"

echo
echo "=== phase 4: assert tool actually ran (file written with sentinel) ==="
# Give claude a moment to consume the approval, run the tool, and
# write the result back to the lattice.
sleep 6

# Direct file-system check — the Write tool wrote $TARGET with $SENTINEL.
[[ -f "$TARGET" ]] && WRITE_OUTPUT="$(cat "$TARGET")" || WRITE_OUTPUT=""
assert_contains "Write target file contains sentinel" "$SENTINEL" "$WRITE_OUTPUT"

# Lattice-side ToolEvent should report success.
TE_STATUS="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT status FROM ToolEvent WHERE name='Write' ORDER BY startedAt DESC LIMIT 1;" 2>/dev/null || echo "")"
assert_eq "Write ToolEvent.status = ok" "ok" "$TE_STATUS"

rm -f "$TARGET"

# Sanity — every replica saw the approved state.
for label in alice bob charlie; do
    case "$label" in
        alice)   LAT="$ALICE_LATTICE" ;;
        bob)     LAT="$BOB_LATTICE" ;;
        charlie) LAT="$CHARLIE_LATTICE" ;;
    esac
    S="$("$SMOKE_SQLITE" "$LAT" "SELECT status FROM ApprovalRequest ORDER BY requestedAt DESC LIMIT 1;")"
    assert_eq "$label sees status=approved" "approved" "$S"
done

capture_pane_to 0 "$ARTIFACTS/alice.txt"
capture_pane_to 1 "$ARTIFACTS/bob.txt"
capture_pane_to 2 "$ARTIFACTS/charlie.txt"

echo
smoke_finish

#!/usr/bin/env bash
# C12 — Peer crash + /reopen over internet (Cloudflare Tunnel).
#
# Reproduces a user-reported failure: peer (bob) crashed mid-session
# while host (alice) was running over the internet. On restart bob
# saw the on-disk scrollback, but:
#   - claude appeared "stuck thinking" (a streaming Turn from before
#     the crash never reconciled)
#   - bob's outgoing chat messages didn't reach alice (WSS write path
#     looked open but wasn't actually plumbed)
#   - alice's new messages weren't appearing on bob (WSS read path
#     was equally dead)
#
# This case has to host over Cloudflare Tunnel (Public visibility) —
# `/reopen` for a peer requires `Session.publicURL` to reconnect
# (`WorkspaceView.activateRecent` line 1071), and a Private LAN host
# never sets that field. The user's exact codepath only fires when
# the cached endpoint is present.
#
# Pre-req: `cloudflared` on PATH (anonymous quick tunnels — no auth).
# Skipped if missing.
#
# Pass criteria:
#   1. bob's pre-crash + during-downtime scrollback present after
#      reopen (catch-up sync over the tunnel).
#   2. alice → bob real-time sync works (live read path).
#   3. bob → alice real-time sync works (live write path).
#   4. no stale `.streaming` Turn rows on bob's lattice.
#   5. bob's Member row shows fresh activity (lastSeenAt < 60s).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

# Pre-flight before smoke_init so we don't leave a dangling tmux
# session if cloudflared isn't installed.
if ! command -v cloudflared >/dev/null 2>&1; then
    echo "SKIP: cloudflared not on PATH (this case needs it for the public tunnel)"
    exit 0
fi

smoke_init "c12"

ARTIFACTS="/tmp/ccirc-smoke-c12"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn 3-pane (alice public host + bob peer; charlie idle) ==="
setup_3p
host_public_session 0 alice "$SMOKE_ROOM_NAME"

resolve_lattices
[[ -z "$ALICE_LATTICE" ]] && smoke_die "no alice lattice"

# Wait for the cloudflared quick-tunnel to come up + publicURL to
# land in alice's Session row. This is the prerequisite for the
# whole test — if the tunnel never connects, the user codepath
# can't run.
echo
echo "=== phase 2: wait for Cloudflare quick-tunnel + publicURL ==="
PUBLIC_URL="$(wait_for_public_url "$ALICE_LATTICE" 60 || true)"
[[ -z "$PUBLIC_URL" ]] && smoke_die "publicURL never landed (tunnel didn't come up in 60s)"
echo "  publicURL=$PUBLIC_URL"

# Bob joins via /join — at this point the room is in alice's LAN
# Bonjour broadcast AND the cloudflared directory bucket; /join
# resolves against both.
echo
echo "=== phase 3: bob joins ==="
join_session 1 bob "$SMOKE_ROOM_NAME"

[[ -z "$BOB_LATTICE" ]] && BOB_LATTICE="$(wait_for_lattice "$BOB_DIR" 30 || true)"
[[ -z "$BOB_LATTICE" ]] && smoke_die "no bob lattice"
wait_for_member_count "$ALICE_LATTICE" 2 30 || smoke_die "alice never saw bob"
wait_for_member_count "$BOB_LATTICE"   2 30 || smoke_die "bob never saw alice"

# Verify bob's local Session row has the publicURL — required for
# /reopen-as-peer to even attempt reconnection.
BOB_PUBLIC_URL="$("$SMOKE_SQLITE" "$BOB_LATTICE" \
    "SELECT publicURL FROM Session WHERE publicURL IS NOT NULL LIMIT 1;" 2>/dev/null || echo "")"
[[ -z "$BOB_PUBLIC_URL" ]] && smoke_die "bob's Session.publicURL not synced"

echo
echo "=== phase 4: baseline bidirectional chat over tunnel ==="
ALICE_PRE_MSG="alice-pre-c12"
BOB_PRE_MSG="bob-pre-c12"
tmux send-keys -t "$SMOKE_SESSION:0.0" "$ALICE_PRE_MSG" Enter; sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.1" "$BOB_PRE_MSG"   Enter; sleep 3

ALICE_PRE_COUNT="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM ChatMessage WHERE text LIKE '%-pre-c12';")"
BOB_PRE_COUNT="$("$SMOKE_SQLITE" "$BOB_LATTICE" \
    "SELECT COUNT(*) FROM ChatMessage WHERE text LIKE '%-pre-c12';")"
assert_eq "alice has both pre-crash messages" 2 "$ALICE_PRE_COUNT"
assert_eq "bob has both pre-crash messages"   2 "$BOB_PRE_COUNT"

echo
echo "=== phase 5: SIGKILL bob (simulate crash) ==="
# Locate bob's pid via env (CCIRC_DATA_DIR is in the process
# environment, not argv — pgrep -f wouldn't see it).
BOB_PID="$(ps eax 2>/dev/null \
    | grep -F "CCIRC_DATA_DIR=$BOB_DIR" \
    | grep -F 'claudecodeirc' \
    | grep -v grep \
    | awk '{print $1}' \
    | head -1)"
[[ -z "$BOB_PID" ]] && smoke_die "couldn't locate bob's claudecodeirc PID"
echo "  killing bob pid=$BOB_PID"
kill -9 "$BOB_PID"
sleep 2
if kill -0 "$BOB_PID" 2>/dev/null; then
    smoke_die "bob's process survived SIGKILL"
fi

echo
echo "=== phase 6: alice keeps using the room while bob is down ==="
ALICE_DURING_DOWN_MSG="alice-during-down-c12"
tmux send-keys -t "$SMOKE_SESSION:0.0" "$ALICE_DURING_DOWN_MSG" Enter
sleep 2
ALICE_HAS_DOWN_MSG="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM ChatMessage WHERE text='$ALICE_DURING_DOWN_MSG';")"
assert_eq "alice has during-down msg" 1 "$ALICE_HAS_DOWN_MSG"

echo
echo "=== phase 7: restart bob from same data dir + /reopen ==="
# `/reopen <name>` goes through `WorkspaceView.activateRecent` →
# `RoomsModel.reopenAsPeer(code:wssEndpoint:joinCode:)` using the
# cached publicURL from the synced Session row. This is the exact
# codepath the user reported as broken.
tmux send-keys -t "$SMOKE_SESSION:0.1" "CCIRC_DATA_DIR='$BOB_DIR' '$SMOKE_BIN'" C-m
sleep 4
tmux send-keys -t "$SMOKE_SESSION:0.1" "/reopen $SMOKE_ROOM_NAME" Enter
# Tunnel reconnect is slower than LAN — give it time.
sleep 10

BOB_LATTICE="$(wait_for_lattice "$BOB_DIR" 20 || true)"
[[ -z "$BOB_LATTICE" ]] && smoke_die "bob lattice gone after restart"

echo
echo "=== phase 8: assert bidirectional sync is LIVE again ==="

# (1) Catch-up replay: the message alice sent during downtime should
#     reach bob via the WSS reconnect.
for i in $(seq 1 30); do
    BOB_DOWN_MSG_COUNT="$("$SMOKE_SQLITE" "$BOB_LATTICE" \
        "SELECT COUNT(*) FROM ChatMessage WHERE text='$ALICE_DURING_DOWN_MSG';" 2>/dev/null || echo 0)"
    [[ "${BOB_DOWN_MSG_COUNT:-0}" -ge 1 ]] && break
    sleep 1
done
assert_eq "bob receives during-down msg via catch-up replay" 1 "$BOB_DOWN_MSG_COUNT"

# (2) Live read path: alice sends now; bob should see within ~3s.
ALICE_POST_MSG="alice-post-rejoin-c12"
tmux send-keys -t "$SMOKE_SESSION:0.0" "$ALICE_POST_MSG" Enter
sleep 3
BOB_POST_COUNT="$("$SMOKE_SQLITE" "$BOB_LATTICE" \
    "SELECT COUNT(*) FROM ChatMessage WHERE text='$ALICE_POST_MSG';")"
assert_eq "bob receives post-rejoin alice msg (live read path)" 1 "$BOB_POST_COUNT"

# (3) Live write path — the headline. User reported "my messages
#     weren't going through". Send a message from bob and assert it
#     lands in alice's lattice.
BOB_POST_MSG="bob-post-rejoin-c12"
tmux send-keys -t "$SMOKE_SESSION:0.1" "$BOB_POST_MSG" Enter
sleep 3
ALICE_POST_COUNT="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM ChatMessage WHERE text='$BOB_POST_MSG';")"
assert_eq "alice receives post-rejoin bob msg (live write path)" 1 "$ALICE_POST_COUNT"

# (4) No stale streaming Turn (claude "stuck thinking" phantom).
BOB_STUCK_TURNS="$("$SMOKE_SQLITE" "$BOB_LATTICE" \
    "SELECT COUNT(*) FROM Turn WHERE status='streaming';" 2>/dev/null || echo 0)"
assert_eq "no stuck-thinking Turn on bob's lattice" 0 "$BOB_STUCK_TURNS"

# (5) Member row freshness — a stale lastSeenAt would let the host
#     classify bob as AFK and drop him from quorum.
BOB_LASTSEEN_AGE="$("$SMOKE_SQLITE" "$BOB_LATTICE" \
    "SELECT CAST((julianday('now') - julianday(lastSeenAt)) * 86400 AS INTEGER) \
     FROM Member WHERE nick='bob';" 2>/dev/null || echo 9999)"
assert_ge "bob lastSeenAt freshness (age in seconds, want < 60)" \
    1 "$((60 - BOB_LASTSEEN_AGE))"

capture_pane_to 0 "$ARTIFACTS/alice.txt"
capture_pane_to 1 "$ARTIFACTS/bob.txt"

echo
smoke_finish

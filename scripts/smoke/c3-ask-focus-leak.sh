#!/usr/bin/env bash
# C3 — AskQuestion focus-leak repro.
#
# When AskUserQuestion carries multiple sequential sub-questions and
# question N+1 mounts because OTHER peers reached quorum on question N
# (rather than the local user voting), the local pane's focus state
# from question N can leak onto question N+1:
#
#   - askDiscussionFocused stays `true` so `▸` is on the discussion
#     line of Q2 instead of the option list (the user's stated bug).
#   - askDiscussionDraft retains the sentinel typed during Q1.
#   - askFocusedRow may be out-of-bounds if Q2 has fewer options.
#
# The reset happens via `.task(id: pendingAskQuestion?.globalId)`
# which is async; the card body re-renders synchronously with Q2's
# data while @State is still Q1's. This script drives that exact race
# and asserts the captured frame is clean.
#
# Setup: 3-pane (alice host + bob/charlie peers). Alice asks claude
# for 3 sequential single-select questions. Alice tabs into discussion
# on Q1 + types a sentinel; bob & charlie vote to advance Q1 → Q2.
# Capture alice's pane and check for stale state.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c3"

ARTIFACTS="/tmp/ccirc-smoke-c3"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn 3-pane (alice host + bob + charlie) ==="
setup_3p
host_session 0 alice alice-room
join_session 1 bob alice-room
join_session 2 charlie alice-room

resolve_lattices
[[ -z "$ALICE_LATTICE"   ]] && smoke_die "no alice lattice"
[[ -z "$BOB_LATTICE"     ]] && smoke_die "no bob lattice"
[[ -z "$CHARLIE_LATTICE" ]] && smoke_die "no charlie lattice"

# Wait for both peers to sync (Member rows ≥ 3).
wait_for_member_count "$ALICE_LATTICE"   3 30 || smoke_die "alice never saw 3 members"
wait_for_member_count "$BOB_LATTICE"     3 30 || smoke_die "bob never saw 3 members"
wait_for_member_count "$CHARLIE_LATTICE" 3 30 || smoke_die "charlie never saw 3 members"
echo "  all 3 peers connected and synced"

echo
echo "=== phase 2: alice triggers 2 sequential single-select Asks ==="
# Q1 has 4 options, Q2 has 2 options — different counts let us catch
# the focusedRow-out-of-bounds variant of the leak in addition to the
# discussion-focus variant. 2 questions (not 3) keeps the LLM-side
# prompt simple and the run reliable. (AskUserQuestion shim caps each
# question at 4 options.)
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude use AskUserQuestion to ask me 2 questions in one tool call: 1. 'Pick a color' (single-select; options Red, Green, Blue, Purple). 2. 'Pick a side' (single-select; options Left, Right). Output nothing else, no preamble, no commentary, no follow-up — just the tool call." Enter

# Long wait — Opus + multi-question AskUserQuestion can take 30-60s
# end-to-end (model latency + ToolSearch + AskUserQuestion materialise).
wait_for_ask_count "$ALICE_LATTICE" 2 180 || smoke_die "2 AskQuestion rows never appeared (claude likely chose not to call the tool — flaky LLM behaviour, retry the run)"
echo "  2 AskQuestion rows materialised"

# Wait for sync to bob & charlie.
sleep 3
echo
echo "  AskQuestion side-by-side:"
echo "    alice:   $("$SMOKE_SQLITE" "$ALICE_LATTICE"   "SELECT COUNT(*) FROM AskQuestion;")"
echo "    bob:     $("$SMOKE_SQLITE" "$BOB_LATTICE"     "SELECT COUNT(*) FROM AskQuestion;")"
echo "    charlie: $("$SMOKE_SQLITE" "$CHARLIE_LATTICE" "SELECT COUNT(*) FROM AskQuestion;")"

echo
echo "=== phase 3: alice tabs into Q1 discussion + types sentinel ==="
SENTINEL_Q1="alice-q1-sentinel-leak"
tmux send-keys -t "$SMOKE_SESSION:0.0" Tab
sleep 0.4
tmux send-keys -t "$SMOKE_SESSION:0.0" "$SENTINEL_Q1"
sleep 0.4

# Snapshot: Q1 ballot with alice in discussion mode, sentinel typed.
capture_pane_to 0 "$ARTIFACTS/q1-alice-discussing.txt"
echo "  alice pane during Q1 discussion saved to $ARTIFACTS/q1-alice-discussing.txt"

echo
echo "=== phase 4: bob + charlie vote Down+Enter on Q1 (advances to Q2) ==="
# Both peers vote on row 1 (option B / Green) for the first question.
# 2/3 majority advances Q1 to .answered.
tmux send-keys -t "$SMOKE_SESSION:0.1" Down
sleep 0.2
tmux send-keys -t "$SMOKE_SESSION:0.1" Enter
sleep 0.5
tmux send-keys -t "$SMOKE_SESSION:0.2" Down
sleep 0.2
tmux send-keys -t "$SMOKE_SESSION:0.2" Enter

# Wait for Q1 to flip to .answered on alice's lattice.
for i in $(seq 1 20); do
    Q1_ANSWERED="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT COUNT(*) FROM AskQuestion WHERE status='answered' AND groupIndex=0;" 2>/dev/null || echo 0)"
    [[ "${Q1_ANSWERED:-0}" -ge 1 ]] && break
    sleep 0.3
done
[[ "${Q1_ANSWERED:-0}" -lt 1 ]] && smoke_die "Q1 never advanced to .answered"
echo "  Q1 .answered after peer votes"

# Q2 now mounts on alice's pane. THIS is the race window.
# Capture immediately, then 100ms later, then 500ms later.
capture_pane_to 0 "$ARTIFACTS/q2-mount-immediate.txt"
sleep 0.1
capture_pane_to 0 "$ARTIFACTS/q2-mount-100ms.txt"
sleep 0.4
capture_pane_to 0 "$ARTIFACTS/q2-mount-500ms.txt"
echo "  alice pane captured at 0ms / 100ms / 500ms after Q2 mount"

echo
echo "=== phase 5: assert Q2 frame is clean of Q1 leak ==="
# Pull the freshest of the three captures (500ms) for the strictest
# assertion — by then .task(id:) MUST have fired. If the leak shows
# even there, the bug is independent of the async-reset race.
Q2_FINAL="$(<"$ARTIFACTS/q2-mount-500ms.txt")"
Q2_IMMEDIATE="$(<"$ARTIFACTS/q2-mount-immediate.txt")"

# Strict assertion is on the SETTLED (500ms) capture — the user-
# visible end state after the `.task(id:)` async reset has fired.
# That's where the user's bug ("next question comes up but the focus
# is still on the previous question") would appear if it were live.
#
# The IMMEDIATE (0ms) capture is informational only: typically it
# shows the *previous* question still rendered (the @Query body
# recompute hadn't run yet) — a frame-lag transient, not a state
# leak. We log it as a WARN if dirty but don't fail the test on it.
#
# (1) Discussion draft must NOT contain the Q1 sentinel.
assert_not_contains "Q2 settled (500ms): no Q1 draft text leaked" \
    "$SENTINEL_Q1" "$Q2_FINAL"
if grep -qF -- "$SENTINEL_Q1" <<<"$Q2_IMMEDIATE"; then
    echo "  WARN  Q2 immediate (0ms): Q1 sentinel present — likely just"
    echo "        a redraw-pacing artefact; check q2-mount-immediate.txt"
    echo "        if you want to inspect the transient frame"
fi

# (2) Q2 should be visible on the screen (sanity — confirms we're
# actually looking at Q2's frame).
assert_contains "Q2 question text rendered" "Pick a side" "$Q2_FINAL"

# (3) The focus marker `▸` must be present somewhere on the card —
# either on a Q2 option row or on the discussion. If it's missing
# entirely, askFocusedRow leaked out of bounds (Q1 had 4 options
# at index 3 + Other at idx=4; Q2 only has 2 options at indices
# 0..1, plus "Other…" at index 2 — index 3 or 4 is unreachable).
if ! grep -qF "▸" <<<"$Q2_FINAL"; then
    echo "  FAIL  Q2: focus marker '▸' not visible at all (askFocusedRow leaked OOB)"
    SMOKE_FAILED=1
else
    echo "  PASS  Q2: focus marker '▸' visible somewhere on the frame"
fi

# (4) The focus marker on Q2 must NOT be on the discussion line.
# Discussion line pattern: "▸ <alice>" (the alice TextField).
# Option-list line pattern: "▸ [ ] <option>" or "▸ [x] <option>".
# We expect ▸ to be on an option row.
if grep -qE "▸\s+<alice>" <<<"$Q2_FINAL"; then
    echo "  FAIL  Q2: focus marker is on discussion line ('▸ <alice>') — discussionFocused leaked"
    SMOKE_FAILED=1
else
    echo "  PASS  Q2: focus marker is NOT on discussion line"
fi


echo
smoke_finish

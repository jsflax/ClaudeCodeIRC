#!/usr/bin/env bash
# C11 — Edit/Write diff renders in `auto` mode (no approval card).
#
# Regression guard for the wire-key bug: `claude -p`'s stream-json
# emits `tool_use_result` (snake_case) as the sibling envelope to a
# tool-result block. The Swift property is `toolUseResult` (camelCase)
# and the default JSONDecoder doesn't translate, so without an
# explicit CodingKeys mapping the field silently decodes as nil.
#
# In `default` mode that's invisible — the approval card renders the
# diff against the on-disk file BEFORE the edit runs, so context is
# correct. But in `auto` the shim's permission-mode short-circuit
# returns `.allow` immediately (`ApprovalMcpShim.swift:163-171`),
# claude runs the tool, and the post-execution `ToolEventRow` is the
# only surface that can render the diff. With `resultMeta` decoded
# as nil it falls back to reading the *already-modified* file —
# `applyEdits` can't find `old_string` in the new content,
# `renderablePatch` returns nil, no diff renders.
#
# Locks in the fix in `StreamJsonEvent.UserMessage` (CodingKeys
# mapping `toolUseResult` ← `tool_use_result`) by checking that
# `ToolEvent.resultMeta` for an `auto`-mode Edit contains both
# `originalFile` and `structuredPatch` — the two fields the diff
# renderer relies on.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c11"

ARTIFACTS="/tmp/ccirc-smoke-c11"
mkdir -p "$ARTIFACTS"

TARGET="/tmp/ccirc-smoke-c11-edit-target.txt"
ORIGINAL_LINE="original-line-c11-$$"
UPDATED_LINE="updated-line-c11-$$"
printf '%s\n%s\n' "$ORIGINAL_LINE" "tail line stays put" > "$TARGET"

echo "=== phase 1: spawn solo alice + host private room ==="
setup_solo
host_session 0 alice "$SMOKE_ROOM_NAME"

ALICE_LATTICE="$(wait_for_lattice "$ALICE_DIR" 20 || true)"
[[ -z "$ALICE_LATTICE" ]] && smoke_die "no alice lattice"

echo
echo "=== phase 2: cycle permission mode default → auto ==="
# Shift-Tab cycle order: default → acceptEdits → plan → auto → default.
# Three BTab presses land us on auto, where the shim short-circuits
# and no ApprovalRequest is created — the path that actually exposes
# the post-execution diff renderer.
tmux send-keys -t "$SMOKE_SESSION:0.0" BTab; sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.0" BTab; sleep 0.3
tmux send-keys -t "$SMOKE_SESSION:0.0" BTab
sleep 1

MODE="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT permissionMode FROM Session ORDER BY rowid DESC LIMIT 1;" 2>/dev/null || echo unknown)"
assert_eq "session permissionMode = auto" "auto" "$MODE"

echo
echo "=== phase 3: alice asks claude to Edit a known file ==="
tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude please use the Edit tool to change the line \"$ORIGINAL_LINE\" to \"$UPDATED_LINE\" in $TARGET. Only do that, nothing else." Enter

# Wait up to 60s for ToolEvent.status='ok' on an Edit row.
STATUS=""
for i in $(seq 1 60); do
    STATUS="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT status FROM ToolEvent WHERE name='Edit' ORDER BY startedAt DESC LIMIT 1;" 2>/dev/null || echo "")"
    [[ "$STATUS" == "ok" ]] && break
    sleep 1
done
assert_eq "Edit ToolEvent.status = ok" "ok" "$STATUS"

# Sanity — the file actually got updated. (If this fails, claude
# wasn't really in acceptEdits and the rest of the assertions are
# meaningless.)
[[ -f "$TARGET" ]] && CONTENT="$(cat "$TARGET")" || CONTENT=""
assert_contains "target file contains updated line" "$UPDATED_LINE" "$CONTENT"
assert_not_contains "target file no longer has original line" "$ORIGINAL_LINE" "$CONTENT"

echo
echo "=== phase 4: assert no approval was generated (proves auto path) ==="
APPROVAL_COUNT="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM ApprovalRequest;" 2>/dev/null || echo 0)"
assert_eq "no ApprovalRequest rows for Edit" "0" "$APPROVAL_COUNT"

echo
echo "=== phase 5: assert ToolEvent.resultMeta carries structuredPatch+originalFile ==="
# This is the point of the test. If the wire-key fix is in place,
# resultMeta will be the JSON of `tool_use_result` and contain both
# fields the diff renderer reads. If the fix is missing, resultMeta
# is empty/null and the renderer falls back to (post-modification)
# disk content + an empty diff.
META="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT resultMeta FROM ToolEvent WHERE name='Edit' ORDER BY startedAt DESC LIMIT 1;" 2>/dev/null || echo "")"
META_LEN="${#META}"

# Save the captured envelope for triage on FAIL.
printf '%s\n' "$META" > "$ARTIFACTS/edit-resultMeta.json"

assert_ge "resultMeta non-trivial length" 50 "$META_LEN"
assert_contains "resultMeta contains structuredPatch" "structuredPatch" "$META"
assert_contains "resultMeta contains originalFile"    "originalFile"    "$META"
assert_contains "resultMeta echoes the original line" "$ORIGINAL_LINE"  "$META"

capture_pane_to 0 "$ARTIFACTS/alice-edit.txt"
rm -f "$TARGET"

echo
echo "=== phase 6: Write-create renders pure-add diff ==="
# Edit's resultMeta carries both `originalFile` and `structuredPatch`,
# so the renderer takes the prebaked-patch path (covered above).
# Write-create's resultMeta has `originalFile: null` and
# `structuredPatch: []` (empty array) — there's no prior file. Without
# the `renderablePatch` Write-create short-circuit, the disk-read
# fallback would read the just-written file and produce
# `updated == original` → empty diff → nothing rendered.
#
# Pane-capture assertion: after the Write runs, the rendered
# scrollback should contain the new content lines (with the unified-
# diff `+` prefix produced by `synthesizePatch`).
WRITE_TARGET="/tmp/ccirc-smoke-c11-write-target.txt"
WRITE_LINE_A="write-c11-a-$$"
WRITE_LINE_B="write-c11-b-$$"
rm -f "$WRITE_TARGET"

tmux send-keys -t "$SMOKE_SESSION:0.0" \
    "@claude please use the Write tool to create the file $WRITE_TARGET with the exact content \"${WRITE_LINE_A}\\n${WRITE_LINE_B}\\n\". Only do that, then stop." Enter

# Wait for the Write ToolEvent to land + run.
WSTATUS=""
for i in $(seq 1 60); do
    WSTATUS="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT status FROM ToolEvent WHERE name='Write' ORDER BY startedAt DESC LIMIT 1;" 2>/dev/null || echo "")"
    [[ "$WSTATUS" == "ok" ]] && break
    sleep 1
done
assert_eq "Write ToolEvent.status = ok" "ok" "$WSTATUS"

# Sanity — the file was written with the requested content.
[[ -f "$WRITE_TARGET" ]] && WCONTENT="$(cat "$WRITE_TARGET")" || WCONTENT=""
assert_contains "Write target has line A" "$WRITE_LINE_A" "$WCONTENT"
assert_contains "Write target has line B" "$WRITE_LINE_B" "$WCONTENT"

# Capture the rendered scrollback. The diff body for a Write-create
# renders the new lines as `+<line>` rows under the tool result.
# Looking for the unique sentinel-bearing rows is enough to confirm
# the diff actually drew (vs. just the `+N lines` summary header).
sleep 2
WRITE_CAP="$(capture_pane 0)"
capture_pane_to 0 "$ARTIFACTS/alice-write.txt"

# DiffBlockView renders each line as `<lineno> <prefix> <text>` —
# look for the diff header + the per-line content sentinels. The
# header (`+2 / -0`) only appears when renderablePatch returned a
# non-nil body; the sentinel match confirms the actual file contents
# made it into the rendered hunk.
assert_contains "diff block header rendered (+2 / -0)" "+2 / -0" "$WRITE_CAP"
assert_contains "diff body shows line A"               "$WRITE_LINE_A" "$WRITE_CAP"
assert_contains "diff body shows line B"               "$WRITE_LINE_B" "$WRITE_CAP"

rm -f "$WRITE_TARGET"

echo
smoke_finish

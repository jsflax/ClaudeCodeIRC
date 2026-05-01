#!/usr/bin/env bash
# scripts/smoke/_lib.sh — shared helpers for the v0.0.1 smoke suite.
# Source this from individual c{N}-*.sh harnesses:
#
#   set -euo pipefail
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#   smoke_init "ccirc-c1"     # sets SESSION + per-case data root
#   setup_3p
#   ...
#   assert_eq "alice has 3 ChatMessage rows" 3 "$(...)"
#
# All helpers exit non-zero on hard failure (no binary, no tmux, etc.)
# and the per-case scripts wrap teardown in a trap so partial state is
# always cleaned.

# ---------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------

SMOKE_REPO_DIR="${SMOKE_REPO_DIR:-/Users/jason.flax/Projects/ClaudeCodeIRC/ClaudeCodeIRC}"
SMOKE_BIN="${SMOKE_BIN:-$SMOKE_REPO_DIR/.build/debug/claudecodeirc}"
SMOKE_SQLITE="${SMOKE_SQLITE:-/Users/jason.flax/Library/Android/sdk/platform-tools/sqlite3}"
SMOKE_LOG="${SMOKE_LOG:-/Users/jason.flax/Library/Logs/ClaudeCodeIRC/ccirc.log}"

# Set by smoke_init before any other helper.
SMOKE_NAME=""
SMOKE_SESSION=""
SMOKE_DATA_ROOT=""
ALICE_DIR=""
BOB_DIR=""
CHARLIE_DIR=""
ALICE_LATTICE=""
BOB_LATTICE=""
CHARLIE_LATTICE=""

SMOKE_FAILED=0

# Random per-run room name suffix. Prior smoke runs publish room
# names to the cloudflared directory worker; cached entries persist
# between runs and `/join <name>` resolves directory first, LAN
# second — so a stable name like "alice-room" lands the peer on a
# defunct WSS URL from a prior run. A unique suffix per smoke
# invocation guarantees the directory doesn't have a stale match.
SMOKE_ROOM_SUFFIX=""

# ---------------------------------------------------------------------
# Initialisation
# ---------------------------------------------------------------------

# smoke_init <case-name>
#   sets SMOKE_SESSION, SMOKE_DATA_ROOT, ALICE/BOB/CHARLIE_DIR, and
#   wipes the data root + log.
smoke_init() {
    SMOKE_NAME="$1"
    SMOKE_SESSION="ccirc-smoke-$SMOKE_NAME"
    SMOKE_DATA_ROOT="${TMPDIR:-/tmp}/ccirc-smoke-$SMOKE_NAME"
    ALICE_DIR="$SMOKE_DATA_ROOT/alice"
    BOB_DIR="$SMOKE_DATA_ROOT/bob"
    CHARLIE_DIR="$SMOKE_DATA_ROOT/charlie"
    SMOKE_ROOM_SUFFIX="$(printf '%04x' $((RANDOM * RANDOM)))"
    SMOKE_ROOM_NAME="$SMOKE_NAME-$SMOKE_ROOM_SUFFIX"

    if [[ ! -x "$SMOKE_BIN" ]]; then
        echo "FAIL: binary not found at $SMOKE_BIN — run 'swift build' first" >&2
        exit 2
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        echo "FAIL: tmux not installed" >&2
        exit 2
    fi

    smoke_teardown >/dev/null 2>&1 || true
    rm -rf "$SMOKE_DATA_ROOT"
    mkdir -p "$ALICE_DIR" "$BOB_DIR" "$CHARLIE_DIR"
    : > "$SMOKE_LOG" 2>/dev/null || true

    trap smoke_teardown EXIT
}

# smoke_teardown — graceful then forceful teardown. The graceful
# step matters because alice's host runs DirectoryPublisher which
# only sends `DELETE /publish/<roomId>` on `stop()` (called from
# `RoomInstance.leave()`). pkill -9 skips that path entirely,
# so without `/leave` first the directory worker accumulates stale
# entries that cause subsequent `/join <name>` calls to land on
# defunct WSS URLs.
#
# Uses `/leave` (not `/delete-room`) so the on-disk lattice files
# survive teardown — failed cases can be triaged via SQLite. The
# data root is wiped on the next `smoke_init` of the same case
# anyway, and unique per-run room names prevent stale-Recent
# pollution between runs.
smoke_teardown() {
    if [[ -n "$SMOKE_SESSION" ]] && tmux has-session -t "$SMOKE_SESSION" 2>/dev/null; then
        # /leave on each pane runs the publisher DELETE + Member-row
        # delete. Best-effort: bail silently if the pane is in a
        # state where /leave doesn't apply (e.g. lobby).
        tmux send-keys -t "$SMOKE_SESSION:0.0" "/leave" Enter 2>/dev/null || true
        tmux send-keys -t "$SMOKE_SESSION:0.1" "/leave" Enter 2>/dev/null || true
        tmux send-keys -t "$SMOKE_SESSION:0.2" "/leave" Enter 2>/dev/null || true
        # Give the DELETE request + sync flush a moment before SIGKILL.
        sleep 1
        tmux kill-session -t "$SMOKE_SESSION" 2>/dev/null || true
    fi
    pkill -9 -f 'claudecodeirc' 2>/dev/null || true
    pkill -9 -f 'claude -p' 2>/dev/null || true
    pkill -9 -f 'mcp-approve' 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------
# Pane / session setup
# ---------------------------------------------------------------------

# setup_3p — spawn 3-pane tmux session, launch one ccirc per pane,
# wait 4s for all instances to come up.
setup_3p() {
    tmux new-session -d -s "$SMOKE_SESSION" -x 270 -y 60
    tmux split-window -h -t "$SMOKE_SESSION:0.0"
    tmux split-window -h -t "$SMOKE_SESSION:0.1"
    tmux select-layout -t "$SMOKE_SESSION:0" even-horizontal

    tmux send-keys -t "$SMOKE_SESSION:0.0" \
        "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN'" C-m
    tmux send-keys -t "$SMOKE_SESSION:0.1" \
        "CCIRC_DATA_DIR='$BOB_DIR' '$SMOKE_BIN'" C-m
    tmux send-keys -t "$SMOKE_SESSION:0.2" \
        "CCIRC_DATA_DIR='$CHARLIE_DIR' '$SMOKE_BIN'" C-m
    sleep 4
}

# setup_solo — single pane; alice only.
setup_solo() {
    tmux new-session -d -s "$SMOKE_SESSION" -x 240 -y 60
    tmux send-keys -t "$SMOKE_SESSION:0.0" \
        "CCIRC_DATA_DIR='$ALICE_DIR' '$SMOKE_BIN'" C-m
    sleep 4
}

# ---------------------------------------------------------------------
# Driving the UI
# ---------------------------------------------------------------------

# host_session <pane> <nick> [room-name]
#   nick the user, run /host, type room name (defaults to <nick>-room
#   for deterministic /join targeting), flip visibility to PRIVATE
#   (LAN-only — skips the cloudflared directory publish so prior
#   smoke runs don't pollute /join via cached directory entries),
#   then Enter to commit.
#
#   HostFormOverlay key model: Tab cycles name→cwd→auth→visibility→name;
#   Space toggles the focused boolean / cycles visibility; Enter submits
#   when focus is on .auth or .visibility.
host_session() {
    local pane="$1" nick="$2" room_name="${3:-${nick}-room}"
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" "/nick $nick" Enter
    sleep 1
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" "/host" Enter
    sleep 2
    # focus on .name; type the name.
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" "$room_name"
    sleep 0.3
    # Tab × 3: .name → .cwd → .auth → .visibility
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" Tab; sleep 0.1
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" Tab; sleep 0.1
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" Tab; sleep 0.1
    # visibility default index is 1 (public). With no groups added,
    # choices = [private, public], so one Space cycles to private.
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" Space
    sleep 0.2
    # Enter submits while focus is on .visibility.
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" Enter
    sleep 4
}

# join_session <pane> <nick> <room-name>
#   nick the user, then run `/join <room-name>` — deterministic match
#   against the discovered set (Bonjour + directory). Avoids the
#   sidebar-navigation flake where stale Public entries from prior
#   smoke runs land Down+Enter on the wrong row.
join_session() {
    local pane="$1" nick="$2" room_name="$3"
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" "/nick $nick" Enter
    sleep 1
    tmux send-keys -t "$SMOKE_SESSION:0.$pane" "/join $room_name" Enter
    sleep 5
}

# wait_for_lattice <data-dir> [timeout-seconds]
#   poll until at least one .lattice file exists under data-dir/rooms.
wait_for_lattice() {
    local dir="$1" timeout="${2:-20}"
    local i=0
    while [[ $i -lt $timeout ]]; do
        local f
        f="$(ls "$dir/rooms/"*.lattice 2>/dev/null | head -1)"
        if [[ -n "$f" ]]; then
            echo "$f"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# resolve_lattices — set ALICE/BOB/CHARLIE_LATTICE for the 3-pane setup.
resolve_lattices() {
    ALICE_LATTICE="$(wait_for_lattice "$ALICE_DIR" 20 || true)"
    BOB_LATTICE="$(wait_for_lattice "$BOB_DIR" 20 || true)"
    CHARLIE_LATTICE="$(wait_for_lattice "$CHARLIE_DIR" 20 || true)"
}

# wait_for_member_count <lattice-file> <expected-count> [timeout]
#   wait until SELECT COUNT(*) FROM Member ≥ expected.
wait_for_member_count() {
    local lat="$1" expected="$2" timeout="${3:-15}"
    local i=0
    while [[ $i -lt $timeout ]]; do
        local n
        n="$("$SMOKE_SQLITE" "$lat" "SELECT COUNT(*) FROM Member;" 2>/dev/null || echo 0)"
        if [[ "${n:-0}" -ge "$expected" ]]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# wait_for_ask_count <lattice-file> <expected-count> [timeout]
wait_for_ask_count() {
    local lat="$1" expected="$2" timeout="${3:-60}"
    local i=0
    while [[ $i -lt $timeout ]]; do
        local n
        n="$("$SMOKE_SQLITE" "$lat" "SELECT COUNT(*) FROM AskQuestion;" 2>/dev/null || echo 0)"
        if [[ "${n:-0}" -ge "$expected" ]]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# wait_for_ask_status <lattice-file> <status> <expected-count> [timeout]
wait_for_ask_status() {
    local lat="$1" status="$2" expected="$3" timeout="${4:-15}"
    local i=0
    while [[ $i -lt $timeout ]]; do
        local n
        n="$("$SMOKE_SQLITE" "$lat" \
            "SELECT COUNT(*) FROM AskQuestion WHERE status='$status';" 2>/dev/null || echo 0)"
        if [[ "${n:-0}" -ge "$expected" ]]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# capture_pane <pane>
capture_pane() {
    local pane="$1"
    tmux capture-pane -t "$SMOKE_SESSION:0.$pane" -p -S -200
}

# capture_pane_to <pane> <file>
capture_pane_to() {
    local pane="$1" file="$2"
    capture_pane "$pane" > "$file"
}

# ---------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------

# assert_eq <label> <want> <got>
assert_eq() {
    local label="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        echo "  PASS  $label  (=$got)"
    else
        echo "  FAIL  $label  want=$want got=$got"
        SMOKE_FAILED=1
    fi
}

# assert_ge <label> <floor> <got>
assert_ge() {
    local label="$1" floor="$2" got="$3"
    if [[ "${got:-0}" -ge "$floor" ]]; then
        echo "  PASS  $label  (got=$got, floor=$floor)"
    else
        echo "  FAIL  $label  floor=$floor got=$got"
        SMOKE_FAILED=1
    fi
}

# assert_contains <label> <substring> <haystack>
assert_contains() {
    local label="$1" needle="$2" hay="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        echo "  PASS  $label  (found '$needle')"
    else
        echo "  FAIL  $label  missing '$needle'"
        SMOKE_FAILED=1
    fi
}

# assert_not_contains <label> <substring> <haystack>
assert_not_contains() {
    local label="$1" needle="$2" hay="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        echo "  FAIL  $label  unexpected '$needle' present"
        SMOKE_FAILED=1
    else
        echo "  PASS  $label  (no '$needle')"
    fi
}

# smoke_finish — print summary, return overall pass/fail status.
smoke_finish() {
    echo
    if [[ "$SMOKE_FAILED" -eq 0 ]]; then
        echo "=== $SMOKE_NAME: PASS ==="
    else
        echo "=== $SMOKE_NAME: FAIL — see /tmp/ccirc-smoke-$SMOKE_NAME ==="
    fi
    return "$SMOKE_FAILED"
}

# smoke_die <reason> — abort the suite hard. Sets SMOKE_FAILED first
# so smoke_finish reports honestly, then prints + exits 1. Use for
# fatal preconditions (no lattice file, peer never connected, etc.)
# where continuing the case would just produce nonsense assertions.
smoke_die() {
    SMOKE_FAILED=1
    echo "FAIL: $1"
    smoke_finish
    exit 1
}

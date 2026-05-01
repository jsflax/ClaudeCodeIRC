#!/usr/bin/env bash
# C13 — UTF-8 input in the chat composer.
#
# User-reported failure: accented characters like "está" don't make
# it into the textfield. Likely affects emojis (multi-byte UTF-8) too.
#
# Test path: alice hosts solo (no peer needed — the bug is in the
# composer's input handling, not in sync), types messages containing
# Latin-extended characters and a few emoji classes (BMP, supplementary
# plane, ZWJ sequences), and the test asserts:
#   1. The exact bytes land in `ChatMessage.text` in the lattice (the
#      composer accepted + persisted them).
#   2. The bytes appear in the rendered scrollback (NCursesUI's
#      TextField + word-wrap handle them through display).
#
# If composer input drops or mangles bytes, (1) fails. If the
# persistence path is fine but the renderer mangles wide chars,
# only (2) fails. Differentiating the two is useful for triage.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
smoke_init "c13"

ARTIFACTS="/tmp/ccirc-smoke-c13"
mkdir -p "$ARTIFACTS"

echo "=== phase 1: spawn solo alice + host private room ==="
setup_solo
host_session 0 alice "$SMOKE_ROOM_NAME"

ALICE_LATTICE="$(wait_for_lattice "$ALICE_DIR" 20 || true)"
[[ -z "$ALICE_LATTICE" ]] && smoke_die "no alice lattice"

echo
echo "=== phase 2: send messages with accented chars + emoji ==="
# Three distinct test strings so failures pinpoint which class breaks:
#   ACCENTED: Latin-extended (2-byte UTF-8) — the user's reported case
#   EMOJI_BMP: a heart (BMP, 3-byte UTF-8) — older terminals support
#   EMOJI_SUPP: 👋 (U+1F44B, 4-byte / supplementary plane) — common emoji range
#   EMOJI_ZWJ: 👨‍👩‍👧 (ZWJ family) — multi-codepoint, exposes width math bugs
ACCENTED="está-aquí-con-café-c13"
EMOJI_BMP="heart-♥-c13"
EMOJI_SUPP="wave-👋-c13"
EMOJI_ZWJ="family-👨‍👩‍👧-c13"

for msg in "$ACCENTED" "$EMOJI_BMP" "$EMOJI_SUPP" "$EMOJI_ZWJ"; do
    tmux send-keys -t "$SMOKE_SESSION:0.0" "$msg" Enter
    sleep 0.5
done
sleep 2

echo
echo "=== phase 3: assert exact bytes landed in ChatMessage.text ==="
# Direct lattice query — the bug, if it exists in the composer, would
# leave the SQLite row missing or with corrupted bytes.
for label in ACCENTED EMOJI_BMP EMOJI_SUPP EMOJI_ZWJ; do
    case "$label" in
        ACCENTED)   want="$ACCENTED" ;;
        EMOJI_BMP)  want="$EMOJI_BMP" ;;
        EMOJI_SUPP) want="$EMOJI_SUPP" ;;
        EMOJI_ZWJ)  want="$EMOJI_ZWJ" ;;
    esac
    got="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
        "SELECT text FROM ChatMessage WHERE text LIKE '%-c13' AND text LIKE '%$(printf '%s' "$want" | head -c 5)%' ORDER BY createdAt DESC LIMIT 1;" \
        2>/dev/null || echo "")"
    assert_eq "$label persisted exactly" "$want" "$got"
done

# Belt + suspenders: total count of -c13 messages should equal what
# we sent. If any row is missing entirely (composer dropped the
# Enter), the count fails even when individual asserts can't see what
# was missing.
TOTAL="$("$SMOKE_SQLITE" "$ALICE_LATTICE" \
    "SELECT COUNT(*) FROM ChatMessage WHERE text LIKE '%-c13';")"
assert_eq "all four UTF-8 messages persisted" 4 "$TOTAL"

echo
echo "=== phase 4: assert the rendered scrollback has the bytes ==="
# Pane capture goes through NCursesUI's render layer. For Latin-
# extended chars this should be a straight pass-through; emojis test
# the cell-width math (CJK-double-width or grapheme-cluster handling).
ALICE_CAP="$(capture_pane 0)"
capture_pane_to 0 "$ARTIFACTS/alice.txt"

# We can match on the unique `-c13` suffix per message, since those
# letters are pure ASCII and survive any UTF-8 mangling — but we
# specifically check that the multi-byte body appears too. Splitting
# the assertion lets us tell whether the row exists at all vs. whether
# its accented body was truncated.
assert_contains "scrollback shows accented body"   "está"   "$ALICE_CAP"
assert_contains "scrollback shows accented suffix" "café"   "$ALICE_CAP"
assert_contains "scrollback shows BMP heart"       "♥"      "$ALICE_CAP"
assert_contains "scrollback shows supplementary 👋" "👋"     "$ALICE_CAP"
# ZWJ family rendering is terminal-dependent — many terminals
# decompose it into the component glyphs. So we match on the leading
# 👨 only; if the ZWJ joiner survives, the family glyph rides
# along. If the terminal decomposed it, at least the first
# component is present.
assert_contains "scrollback shows ZWJ leader 👨"   "👨"      "$ALICE_CAP"

echo
smoke_finish

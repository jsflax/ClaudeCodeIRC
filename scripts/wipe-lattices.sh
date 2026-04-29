#!/usr/bin/env bash
# wipe-lattices.sh — nuke ccirc's on-disk lattices + prefs for the
# current user. Debug-only: useful while we're still landing
# wire-format / schema changes that aren't migration-friendly, so a
# stale lattice from a previous run breaks the next launch.
#
# Wipes:
#   ~/Library/Application Support/ClaudeCodeIRC
#       ├── prefs.lattice        (nick, lastCwd, paletteId, groups…)
#       └── rooms/<code>.lattice (one per hosted/joined room)
#
# Does NOT touch the tmux test panes' data dirs (they live under
# $TMPDIR and `scripts/tmux-e2e.sh teardown` already cleans those).
#
# Usage:
#   scripts/wipe-lattices.sh         # confirm before wiping
#   scripts/wipe-lattices.sh -y      # skip confirm
#   scripts/wipe-lattices.sh --kill  # pkill claudecodeirc first
#   scripts/wipe-lattices.sh -y --kill
#
# Why this is a script not a brew uninstall:
#   `brew uninstall claudecodeirc` removes the binary but not user
#   data under Application Support — that's by design (uninstall
#   shouldn't clobber chat transcripts). For debugging the wire
#   format we want exactly the opposite.

set -euo pipefail

ASSUME_YES=0
KILL_PROCS=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes)   ASSUME_YES=1 ;;
        --kill)     KILL_PROCS=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

APP_SUPPORT="$HOME/Library/Application Support/ClaudeCodeIRC"

if [[ ! -e "$APP_SUPPORT" ]]; then
    echo "nothing to wipe — $APP_SUPPORT does not exist"
    exit 0
fi

size="$(du -sh "$APP_SUPPORT" 2>/dev/null | awk '{print $1}')"
echo "will remove:"
echo "  $APP_SUPPORT  ($size)"

if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "proceed? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

if [[ $KILL_PROCS -eq 1 ]]; then
    pkill -9 -f 'claudecodeirc' 2>/dev/null || true
    echo "killed any running claudecodeirc processes"
fi

rm -rf "$APP_SUPPORT"
echo "removed $APP_SUPPORT"
echo "done"

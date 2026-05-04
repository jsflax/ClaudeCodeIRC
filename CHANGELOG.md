# Changelog

All notable changes to ClaudeCodeIRC are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.7] — 2026-05-04

### Added

- **C9 e2e — `Shift-Tab` cycler walk** (`PermissionModeCycleTests`).
  Hosts a room and walks `default → accept-edits → plan → auto →
  default`, asserting the status-bar mode marker after each press.
- **C10 e2e — Shift-Tab cycler after `ExitPlanMode` vote**
  (`PermissionModeAfterExitPlanTests`). Drives the real claude
  binary: cycle into plan mode, `@claude` requests an action,
  `ExitPlanMode` plan card materialises, vote "Yes — auto mode",
  then verify Shift-Tab still cycles past `auto` back to `default`.

### Changed

- **Shift-Tab cycler re-resolves `Session` from the lattice** on each
  press (`room.lattice.objects(Session.self).first`) instead of
  reading through the cached `room.session` Swift wrapper. Defensive
  — no confirmed Lattice staleness bug, but the new C10 test only
  passes with this change. Worth a follow-up to determine whether
  Lattice's cross-instance observation is leaking a stale wrapper.
- **`ApprovalMcpShim.setSessionMode`** drops its
  `beginTransaction()/commitTransaction()` wrapper around a single
  property write. No semantic difference for one write; the bracket
  was unnecessary scaffolding.

### Known issues

- **Claude CLI `--resume` intermittently ignores `--permission-mode`.**
  Reproducible with raw `claude -p` calls — after a few `--resume`
  spawns, the model reports "Default mode" even when
  `--permission-mode plan` (or any non-default) is on the command
  line. Recovers on its own after a few more turns. Filed upstream;
  no workaround in ccirc beyond starting a fresh session.

## [0.0.6] — 2026-05-04

### Added

- **`/delgroup <name|hash>`** removes a `LocalGroup` row from your local
  prefs. Matches by name (exact, case-insensitive) or hash prefix; on
  ambiguous names, the error message lists the candidates with their
  6-char hash suffix so you can re-issue with the disambiguating
  prefix. Does NOT unpublish a hosted room from the directory bucket
  — peers who hold the secret continue to see the listing; only the
  local sidebar section disappears.

### Fixed

- **Group rooms now show their group name in the bottom status bar.**
  Was reading `[public:ready]` for any non-private room. Now resolves
  `Session.groupHashHex` against the local `LocalGroup` rows and
  prints `[canary:ready]` (or `[canary:pending]` while the tunnel is
  warming up). Falls back to a 6-char hash prefix when the local user
  doesn't hold the group secret.
- **Recent-rooms sidebar shows group name** instead of the bare
  `group` enum rawValue for non-private recent rooms. Same lookup
  path as the status-bar label.
- **Same-named groups in the sidebar are now disambiguated** with a
  `·<hash6>` suffix on the section header, matching the contract the
  `LocalGroup` doc comment has carried since the model was introduced
  ("two groups with the same `name` but different secrets coexist;
  the UI disambiguates them with `addedAt` or a hash prefix"). The
  full-name display is preserved when names are unique.
- **`/addgroup` now warns on a name collision.** When pasting an
  invite whose name matches an existing local group with a different
  hash, you see "another group with this name exists locally; the
  sidebar shows them as `<name> ·<hash>`". Prevents the silent
  "I added it but it looks like a duplicate" confusion that surfaced
  this fix series.

## [0.0.5] — 2026-05-04

### Fixed

- **Host can rejoin own room after `/leave`.** alice hosts → bob joins →
  alice `/leave`s → alice tries to come back → previously, neither side
  saw the other's messages. Three architectural gaps fixed end-to-end:
  - `RoomInstance.leave()` no longer cascade-deletes the host's `Member`
    row. The cascade was wiping ChatMessage authorship and ownership
    along with presence, so `activateRecent` had no Member with
    `isHost=true` to match against and routed alice to `reopenAsPeer`,
    which fails on LAN rooms. Host /leave now flips `isAway=true` and
    clears `session.host`; `isHost` stays true as the durable owner
    marker. Peer /leave still cascades.
  - Peer host-departure signal moved from "Member globalId vanished"
    to `session.host == nil`. New Session observer fires
    `ejectIfHostLeft`; the legacy Member-delete path is kept as a
    defensive fallback.
  - `RoomsModel.leave(_:)` now re-runs `loadPersistedRooms` so the
    just-left room appears in the Recent sidebar without requiring an
    app restart. The scan is now idempotent.
- **WSS sync ownership now handles URL changes.** When two `lattice_db`
  instances on the same SQLite path race for the per-path `flock`,
  `setup_sync_if_configured` now recognizes a same-process sibling on
  a different `wssEndpoint` as a URL-change scenario and kicks the
  sibling out via `teardown_sync(fire_handoff: false)`. Previously the
  sibling-handoff in `teardown_sync` could resurrect a dormant ghost
  (created by `Snapshot.Materializer`'s cross-actor `resolve`) on the
  stale URL, after which the new opener's `setup_sync` silent-skipped
  on flock contention — leaving the process with no live synchronizer
  ("broadcast 0 peers" forever). Lands in LatticeCore@dc371c1.
- **Bonjour TXT hostname** now prefers the `.local` answer from
  `Host.current().names` when `ProcessInfo.hostName` returns the bare
  BSD hostname. Bare hostnames are unresolvable to peers; observed
  concretely as `ws://mac:PORT/...` on a fresh boot before mDNS
  resolution stabilizes.

### Added

- **Optional Lattice C++ logging.** Set `LATTICE_LOG_LEVEL` env var
  (`debug`/`info`/`warn`/`error`/`off`) at app launch — Lattice writes
  to `~/Library/Logs/ClaudeCodeIRC/lattice-<pid>.log` (separate from
  `ccirc.log` so the C++ output doesn't interleave). Off by default.

### Tests

- New `C7_HostRejoinAfterLeaveTests` covers the user-reported flow
  end-to-end: alice host → bob join → message exchange → alice /leave
  → both auto-eject → alice /reopen (no relaunch) → bob /join →
  bidirectional post-rejoin messages.
- New `RoomsModelLeaveTests` asserts recents repopulate on leave and
  host's Member persists with `isHost=true && isAway=true &&
  session.host=nil`.
- C6 cascade-fragmentation test actor swapped from alice (host) to
  bob (peer) since host /leave no longer cascades.
- `RoomsModelDeleteRoomTests/leaveDeletesSelfMemberRow` updated to
  `leaveKeepsHostMemberFlippedAway` for the new semantics.
- New Lattice-layer `URLChangeSyncTests` verifies the sync-handover
  fix at the library boundary.

## [0.0.4] — 2026-05-02

### Added

- **Silent self-update on launch.** `Updater.runInBackground` checks
  GitHub Releases for a newer published tag, downloads the tarball +
  sidecar SHA256, verifies, and atomically swaps the on-disk binary.
  The running process keeps executing on its already-loaded inode;
  the new version takes effect on the next launch. Failure modes are
  silent (logged to `ccirc.log`).
- **Per-member typing indicator.** `Member.typingUntil: Date?` drives
  an ephemeral `<nick> typing…` row in the message list for any
  non-self member whose timestamp is still in the future. Composer
  watches `draft` with a 250ms debounce and re-arms the field at
  ~1/1.5s while the user is actively typing; empty draft + send
  both clear it.
- **Terminal bell on background-room traffic.** Non-active rooms
  emit BEL (0x07) via `Term.bell()` when a foreign user/action
  message lands. The active room stays silent; self / system /
  assistant content is filtered upstream — only peer chat triggers.
- **Multi-byte UTF-8 input** in the chat composer (NCursesUI
  TextField fix). Accented characters (`á`, `é`, `ñ`, …), BMP emoji
  (`♥`), supplementary-plane emoji (`👋`, `🎉`), and ZWJ
  sequences (`👨‍👩‍👧`) all land verbatim instead of being
  silently dropped. Pre-fix, every byte ≥ 0x7E was rejected.

### Fixed

- Peer `/reopen` over Cloudflare Tunnel now actually reconnects
  (carried from the v0.0.3 changes — releasing as v0.0.4 since
  v0.0.3 was not separately tagged for distribution).

### Tests

- New in-process E2E target `ClaudeCodeIRCE2ETests` ports the C1–C6
  smoke cases to XCUITest-style Swift tests using the in-process
  NCUITest probe — chat baseline, single-select Ask majority,
  AskQuestion focus-leak, stuck-thinking-on-Ctrl-C-rejoin,
  peer-ESC interrupt fanout, and host-leave dangling-author guard.
  Runs under `swift test` alongside the unit suite; no tmux harness
  needed.
- `scripts/smoke/c14-typing-indicator.sh` and
  `scripts/smoke/c15-bell-non-active-room.sh` cover the new typing
  indicator and bell behaviours end-to-end.

## [0.0.3] — 2026-05-02

### Fixed

- Peer `/reopen` over Cloudflare Tunnel now actually reconnects.
  `Session.publicURL` is the host's bare tunnel origin
  (`https://*.trycloudflare.com`); `PublicURLObserver` translated it
  to `wss://.../room/<code>` before calling `RoomInstance.swap`, but
  `WorkspaceView.activateRecent` (the `/reopen` codepath) handed the
  raw https URL straight to `reopenAsPeer`. Lattice's WSS upgrade
  silently failed and sync was dead — the room rendered
  `[public:ready]` locally but no messages flowed in either
  direction. Translation logic is now a single helper
  (`PublicURLObserver.wssEndpoint(forPublicURL:roomCode:)`) used by
  both call sites.
- `RoomInstance.swap` short-circuits when the incoming endpoint +
  joinCode match the current connection. Reopening Lattice for an
  unchanged target left cached `@Query` results pointing at the
  closed C++ `swift_lattice`, and the next view read SIGSEGV'd in
  `database::query` with a null `db_`. Manifested as a crash on
  first peer-join with long history (catch-up triggered a same-URL
  swap during initial render).

### Tests

- `scripts/smoke/c12-peer-crash-rejoin.sh` — end-to-end repro of the
  reopen-over-tunnel bug. Hosts public via cloudflared, peer joins,
  SIGKILLs the peer, host keeps using the room during downtime,
  peer restarts and runs `/reopen`, asserts catch-up replay +
  bidirectional live sync. Skipped if `cloudflared` isn't on PATH.

## [0.0.2] — 2026-05-01

### Fixed

- File diffs now render in `auto` mode (and any other path that
  bypasses the approval card). Two regressions were stacked:
  - `claude -p`'s stream-json envelope keys the rich tool-result
    sibling as `tool_use_result` (snake_case), but `StreamJsonEvent.UserMessage`
    declared the property as `toolUseResult` with no `CodingKeys`
    mapping — the field silently decoded as nil, leaving
    `ToolEvent.resultMeta` empty. Without it, `ToolEventRow`'s
    post-execution diff renderer had nothing to draw and fell back to
    re-reading the just-modified file (producing an empty diff).
  - `ToolDiffPreview.renderablePatch` had no Write-create branch.
    A fresh-file Write produces `originalFile: null` /
    `structuredPatch: []` in `tool_use_result`, so the
    `applyEdits`-against-disk fallback would compare the new content
    against itself and return nil. Now a single pair with empty `old`
    short-circuits to a pure-add unified diff.

### Tests

- `StreamJsonEventTests.decodesUserToolUseResultSnakeCase` pins the
  wire-key mapping at the decoder layer.
- `scripts/smoke/c11-auto-diff.sh` exercises the full `auto`-mode
  Edit + Write-create render path end-to-end (host + spawn `claude
  -p` + `ToolDiffPreview` + `DiffBlockView`).

## [0.0.1] — 2026-05-01

First public release. ClaudeCodeIRC is a multi-user terminal chat for
Claude Code: one host runs `claude -p`, peers join over LAN (Bonjour)
or the internet (Cloudflare Tunnel + a public lobby) and collaborate
on whatever Claude is doing — voting on tool approvals, answering
`AskUserQuestion` ballots, discussing midstream, and interrupting
turns from any pane.

### Core

- First-run nick picker overlay: a fresh `CCIRC_DATA_DIR` (no
  `prefs.nick`) presents a mandatory `Welcome to ClaudeCodeIRC`
  modal. ESC is no-op; Enter validates (non-empty, no whitespace)
  and persists the nick. Subsequent launches skip the overlay.
- Top-bar shows the per-device nick alongside the active room:
  `claude-code.irc │ <alice> │ alice-room │ HH:mm`. Visible in the
  lobby state too so users can confirm their handle without joining
  a room first.
- 3-column NCursesUI workspace: sessions sidebar, scrollback +
  composer, members sidebar.
- Tab-cycled focus across panes; arrow-key navigation inside each
  sidebar; slash-command popup with prefix completion.
- IRC-style chat: `/nick`, `/me`, `/topic`, `/afk`, `/clear`, `/side`
  (banter excluded from Claude's context), `/help`, `/members`.
- Per-nick deterministic colours; word-wrap with hanging indent;
  full-height vertical dividers and full-width section rules.
- Palette selector (`/palette`) — phosphor / amber / modern / claude
  themes; persisted in prefs.
- Live clock in the top bar (only the clock view re-renders on tick).

### Sync transport

- Lattice-as-wire: every visible event is a Lattice row; sync rides
  the Lattice WebSocket protocol — no hand-rolled framing.
- LAN: Bonjour service discovery, automatic LAN sidebar section.
- Internet: Cloudflare Tunnel for the host's WSS endpoint; a
  Cloudflare Worker public directory ([Worker source][worker]) for
  discovery. Visibility cycler: private (LAN-only) / public / group
  (per-secret bucket).
- Group invites: `/newgroup <name>` produces a paste-able
  `ccirc-group:v1:` invite; `/addgroup` consumes one.
- Join over internet: paste a `ccirc-join:v1:<code>:<token>:<wssURL>`
  link, or pick a row from the Public/group sidebar section.
- WebSocket keepalive on the host; auto-reconnect on peers when the
  tunnel idles.

### Claude integration

- Headless `claude -p` driver; streaming JSON events ingested into
  Lattice as `AssistantChunk` rows.
- MCP approval shim — every Claude tool call appears as an
  `ApprovalRequest`; democratic Y/A/D voting across present peers
  with strict-majority resolution (`(n/2)+1`).
- ToolEvent rendering: per-tool cards in the scrollback (Bash,
  Write/Edit with diff preview, TodoWrite list, ExitPlanMode plan
  card, AskUserQuestion ballot).
- AskUserQuestion ballot: arrow-key navigation, single-select +
  multi-select, "Other…" free-text entry, present-quorum-aware
  threshold.
- Inline AskQuestion discussion thread: peer-to-peer comments
  attached to a pending question; comments stay peer-only and never
  reach Claude.
- Permission modes (default / acceptEdits / plan / auto / bypass);
  ⇧Tab cycles host-side. Mode rendered in the status bar with role
  prefix + colour.
- ESC-to-interrupt the streaming turn — works from any pane (peer
  flips a `Turn.cancelRequested` flag, host observer kills the
  subprocess); fanout notice on every replica.
- Host statusline: pipes a configurable command's stdout into the
  bottom strip, syncs to peers.
- First-run `Doctor` check warns when `claude` or `cloudflared` are
  missing from PATH.

### Rendering polish

- Per-message word-wrap with hanging indent.
- Display-time fenced-code blocks (syntax-highlighted) and unified
  diffs (gutter colours + context lines).
- Plan card paragraph reflow.
- Pin-to-bottom auto-scroll with position-preserving behaviour
  during streaming.
- Inline "thinking…" row that pauses while a tool is mid-flight.
- Thinking-as-inline-pending-message rendering (no separate banner).

### Persistence + recovery

- Rooms persist to `<DATA_DIR>/rooms/<code>.lattice`; `Recent`
  sidebar section reopens them on next launch.
- `/reopen [name]` re-enters a persisted room without needing
  Bonjour discovery.
- Orphan-cleanup on host rejoin: Turns left `.streaming`,
  AskQuestions left `.pending`, ToolEvents left `.running`,
  ApprovalRequests left `.pending` are all reconciled to terminal
  states inside one transaction — fixes the "permanently
  thinking" stuck state after Ctrl+C / crash.
- `/leave` — gracefully disconnect (publisher DELETEs directory
  entry, Member row removed, peers see us depart). Lattice file
  preserved.
- `/delete-room` — leave AND remove the on-disk lattice file +
  drop the Recent entry. The room is gone for good.
- `CCIRC_DATA_DIR` env var override for sandboxed runs / parallel
  test isolation.

### Distribution

- Homebrew tap: `brew install jsflax/tap/claudecodeirc`.
- GitHub Actions release workflow builds on macos-15, ad-hoc signs,
  publishes the binary tarball to a tagged GitHub Release.
- Swift 6.3 dev snapshot pulled in CI/release until macos runners
  ship it natively.

### Smoke / test coverage

- Unit suites: 200+ tests covering AskTally, ApprovalTally,
  TurnManager, RoomsModel reopen + group + delete-room, RoomInstance
  swap, JoinCode/GroupInviteCode/GroupID parsers, DirectoryHTTP,
  TunnelManager stderr extraction, MessageBodyParser, syntax
  highlighter, transcript reader, etc.
- 3-peer end-to-end smoke suite under `scripts/smoke/` (C1–C9,
  runnable via `scripts/smoke/run-all.sh`) gating the v0.0.1 ship
  criteria — 3-peer chat, single-select majority, focus-leak
  repro, stuck-thinking recovery, peer-ESC fanout, discussion
  sync, approval quorum, multi-select wait-for-all, perf
  non-regression.
- 3-pane interactive harness: `scripts/tmux-e2e-3p.sh`.

[worker]: https://ccirc-lobby.jsflax.workers.dev

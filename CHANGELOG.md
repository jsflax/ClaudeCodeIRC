# Changelog

All notable changes to ClaudeCodeIRC are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

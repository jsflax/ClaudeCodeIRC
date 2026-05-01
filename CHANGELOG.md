# Changelog

All notable changes to ClaudeCodeIRC are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] — 2026-05-01

First public release. ClaudeCodeIRC is a multi-user terminal chat for
Claude Code: one host runs `claude -p`, peers join over LAN (Bonjour)
or the internet (Cloudflare Tunnel + a public lobby) and collaborate
on whatever Claude is doing — voting on tool approvals, answering
`AskUserQuestion` ballots, discussing midstream, and interrupting
turns from any pane.

### Core

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

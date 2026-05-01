# claude-code.irc

A multi-user terminal chat for [Claude Code]. One host runs `claude
-p`, peers join over LAN or the internet, everyone collaborates on
whatever Claude is doing — vote on tool approvals, answer
`AskUserQuestion` ballots, discuss midstream, interrupt turns from
any pane.

```
 claude-code.irc │ <alice> │ alice-room │ topic: refactor User.swift │ 14:03 
─────────────────────────────────────────────────────────────────────────────
─── sessions (1) ──────│ 14:02 <alice> @claude refactor User.swift     │ ─── users (3) ─────
   alice-room          │               so it uses async/await          │   alice ★ host
─── recent (2) ────────│ 14:02 <claude> I'll start by reading the      │   bob     online
   prod-debug 🔒       │                current implementation.        │   charlie online
   payments-canary     │                                               │
─── lan ───────────────│ ┌─ Read ─────────────────────────────── ✓ ─┐  │ ─── statusline ────
   bobs-mac            │ │ Sources/Models/User.swift                │  │  Opus 4.7  ⏵⏵
─── public (1) ────────│ │   42 lines · synchronous                 │  │  context: 84%
   open-jam @kelly     │ └──────────────────────────────────────────┘  │  cwd: ~/proj/app
─── canary (2) ────────│                                               │
   payments-debug      │ ┌─ Bash ─────────────────────── awaiting Y/A/D ┐
   migration-staging   │ │ $ swift build -c release                  │  │
─── infra (0) ─────────│ │                                           │  │
                       │ │ alice ✓   bob ✓   charlie ?               │  │
                       │ └───────────────────────────────────────────┘  │
                       │                                               │
                       │ 14:02 <bob> /side smoke ran clean on my box   │
                       │                                               │
                       │ ┌─ claude is asking ───────── pending (0/3) ─┐ │
                       │ │ Which approach for the refactor?           │ │
                       │ │                                            │ │
                       │ │   ▸ [ ] async/await throughout             │ │
                       │ │     [ ] callback adapter shim              │ │
                       │ │     [x] both — feature-flag the swap       │ │
                       │ │     [ ] Other…                             │ │
                       │ │                                            │ │
                       │ │ ─── discussion ───                         │ │
                       │ │   <bob>     async-await is cleaner long-…  │ │
                       │ │   <charlie> shim is faster to ship though  │ │
                       │ │   <alice>                                  │ │
                       │ │                                            │ │
                       │ │ quorum: 1 / 3   ↑/↓ move · Enter toggle ·  │ │
                       │ │                  Space commit · Tab focus  │ │
                       │ └────────────────────────────────────────────┘ │
─── [+] hints ─────────│                                               │
   /host /reopen <name>│ ▸ thinking…                                   │
   /addgroup           │                                               │
─────────────────────────────────────────────────────────────────────────────
[alice(*)] [alice-room] [open] [public:ready]                       14:03 │
[alice-room] > █
Alt+1..9 session  ^N/^P next/prev  Tab complete/pane  / command  Y/A/D approve  ⇧Tab mode
```

## Install

### Homebrew (macOS, Apple Silicon)

```sh
brew install jsflax/tap/claudecodeirc
```

### From source

```sh
git clone https://github.com/jsflax/ClaudeCodeIRC.git
cd ClaudeCodeIRC
swift build -c release
.build/release/claudecodeirc
```

Requires Swift 6.3 or later.

## Requirements

- **macOS 15+** (Apple Silicon).
- **[`claude`][Claude Code]** on `PATH` — the host process spawns
  `claude -p` to drive the AI.
- **[`cloudflared`][cloudflared]** on `PATH` — only needed if you
  host with `Public` or `Group` visibility (LAN-only `Private` rooms
  don't use it). The first run prints a doctor report listing
  anything missing.

## Quickstart

1. Run `claudecodeirc`. On first launch you pick a nickname.
2. `/host` to start a room. Pick a name and visibility:
   - **Private** — LAN-only, peers find you over Bonjour.
   - **Public** — listed in the public directory; anyone with the
     join link can connect over the internet via Cloudflare Tunnel.
   - **Group** — listed in a private group bucket; only people who
     pasted the group invite can see your room.
3. Chat normally; `@claude <prompt>` invokes the model. When Claude
   wants to run a tool, all present peers vote `Y`/`A`/`D` —
   strict majority approves.

### Joining

- **LAN** — peers see your hostname under `── lan ──` in their
  sidebar. Tab to focus the sidebar, arrow to your row, Enter.
- **Internet** — you (the host) get a `ccirc-join:v1:…` link;
  share it; the joiner pastes it into `/addgroup` (or types
  `/join <room name>` if it's in the public directory).

### Useful commands

| Command | Effect |
|---|---|
| `/help` | full command list |
| `/nick <name>` | change nickname |
| `/host` | open the host form |
| `/join [name]` | join a discovered room |
| `/reopen [name]` | re-enter a previously joined room from disk |
| `/leave` | leave the active room (file preserved) |
| `/delete-room` | leave AND remove the on-disk lattice |
| `/topic <text>` | set the session topic |
| `/me <action>` | emote |
| `/afk [reason]` | toggle away — excluded from vote quorum |
| `/clear` | hide scrollback up to now (local only) |
| `/palette` | pick a UI palette |
| `/kick <nick>` | host-only: remove a member |
| `Tab` | cycle focus across panes / complete nick / switch ballot focus |
| `Esc` | interrupt the streaming claude turn |
| `Y` / `A` / `D` | approve / always-allow / deny a pending tool |

## Architecture

- **Pure star topology.** The host runs the only `claude -p` and
  owns the only authoritative copy of the room database
  ([Lattice]). Peers maintain local replicas synced over
  WebSocket — the host is the hub, peers are spokes.
- **Lattice as the wire format.** Every visible event (chat
  messages, tool calls, votes, ballots, comments) is a Lattice
  row. Sync rides Lattice's own WebSocket protocol — no
  hand-rolled framing.
- **Discovery.**
  - LAN: Bonjour (`_claudecodeirc._tcp`).
  - Internet: a small Cloudflare Worker public directory + the
    host's Cloudflare Tunnel URL.
- **Voting on Claude tool calls.** When `claude` requests a tool,
  the host's MCP shim writes an `ApprovalRequest` row that syncs
  to all peers. Each peer's `Y`/`A`/`D` keypress writes an
  `ApprovalVote` row. The host's tally coordinator resolves on
  strict majority and routes the result back to claude.
- **`AskUserQuestion`** — a multi-question ballot card. Same vote
  mechanism, but multiple options + an optional inline discussion
  thread (peer-to-peer comments that claude doesn't see).

## Development

```sh
swift test                # unit suites
scripts/tmux-e2e-3p.sh    # 3-pane interactive harness
scripts/smoke/run-all.sh  # automated smoke suite (~5 min)
```

The smoke suite requires `tmux`, the `jsflax/Lattice` SQLite
sister-binary, and the same `claude` PATH dependency the app uses.

## Contributing

Issues and PRs welcome at
[github.com/jsflax/ClaudeCodeIRC](https://github.com/jsflax/ClaudeCodeIRC).

[Claude Code]: https://claude.com/claude-code
[cloudflared]: https://github.com/cloudflare/cloudflared
[Lattice]: https://github.com/jsflax/lattice

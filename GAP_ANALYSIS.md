# Gap Analysis: zclaw vs OpenClaw/IronClaw/NullClaw

## Overview

zclaw is a multi-channel AI gateway written in Zig, porting [OpenClaw](https://github.com/openclaw/openclaw) (TypeScript) to achieve smaller binaries, faster startup, and lower resource usage while maintaining feature parity.

## Comparison Table

| Metric | OpenClaw (TS) | NullClaw (Zig) | zclaw |
|--------|--------------|-----------------|-------|
| Binary size | 1.52 GB install | 678 KB | **727 KB** (ReleaseSmall) |
| Startup | ~6 sec | <2 ms | **~2 ms** |
| Memory | 1.52 GB | ~1 MB | **<5 MB** |
| Tests | ~1,000 | 3,230+ | **3,841+** |
| Providers | 20+ | 22+ | **12** (3 native + 9 via OpenAI-compat) |
| Channels | 15+ built-in | 17 | **6** (Telegram, Discord, Slack + 3 stubs) |
| Agent loop | Full | Full | **Full** (wired end-to-end) |
| CLI | 13 commands | Full | **13 commands** (all wired to real data) |
| Config | JSON5 | OpenClaw-compat | **JSON + JSON5 preprocessor** |

## Architecture

```
┌──────────────────────────────────────────────────┐
│                   main.zig                        │
│  CLI dispatch ─── Config loader ─── Signal handler │
│                                                    │
│  ┌─────────┐  ┌──────────┐  ┌──────────────────┐ │
│  │ httpz   │  │ Telegram │  │ Discord polling  │ │
│  │ server  │  │ polling  │  │ thread           │ │
│  │ /health │  │ thread   │  └──────────────────┘ │
│  │ /ws     │  └──────────┘  ┌──────────────────┐ │
│  │ /slack  │                │ Slack webhook    │ │
│  └─────────┘                │ /slack/events    │ │
│                             └──────────────────┘ │
│  ┌──────────────────────────────────────────────┐ │
│  │           Agent Runtime (runLoop)             │ │
│  │  ┌──────────┐  ┌──────────┐  ┌────────────┐ │ │
│  │  │ Provider │  │ Tool     │  │ Session    │ │ │
│  │  │ Dispatch │  │ Registry │  │ Persistence│ │ │
│  │  └──────────┘  └──────────┘  └────────────┘ │ │
│  └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

## Module Inventory (74 source files)

### Core Infrastructure
- `src/infra/` — errors, logging, env helpers, HTTP client with mock transport
- `src/config/` — schema, JSON/JSON5 loader, file watcher, env var substitution

### Agent System
- `src/agent/runtime.zig` — Agent execution loop with tool dispatch
- `src/agent/session.zig` — JSONL session persistence
- `src/agent/prompt.zig` — System prompt builder (IDENTITY/SKILLS/MEMORY)
- `src/agent/compaction.zig` — Context compaction with token estimation
- `src/agent/failover.zig` — Provider failover, auth rotation, cooldown

### Providers
- `src/providers/anthropic.zig` — Anthropic Messages API (Claude)
- `src/providers/openai.zig` — OpenAI Chat Completions API
- `src/providers/gemini.zig` — Google Gemini API
- `src/providers/openai_compat.zig` — 9 OpenAI-compatible presets (Groq, DeepSeek, Mistral, xAI, Fireworks, Cerebras, Perplexity, OpenRouter, Together)
- `src/providers/sse.zig` — Server-Sent Events parser
- `src/providers/types.zig` — Common provider types

### Channels
- `src/channels/telegram.zig` — Telegram Bot API with polling loop
- `src/channels/discord.zig` — Discord Gateway with polling
- `src/channels/slack.zig` — Slack Events API webhook handler
- `src/channels/plugin.zig` — Channel plugin vtable and registry
- `src/channels/routing.zig` — Session key resolution, agent routing
- `src/channels/access.zig` — DM/group access policy, mention detection

### Gateway
- `src/gateway/server.zig` — Gateway context, connection state
- `src/gateway/protocol/` — RPC frames, auth, method dispatch
- `src/gateway/state.zig` — Connection registry, presence tracking
- `src/gateway/methods.zig` — RPC method handlers
- `src/gateway/rate_limit.zig` — Sliding window + fixed window limiters

### Memory System
- `src/memory/manager.zig` — Document store with keyword search
- `src/memory/chunker.zig` — Text chunking with overlap
- `src/memory/search.zig` — Hybrid search (BM25 + vector), MMR, cosine
- `src/memory/embeddings.zig` — Embedding provider client
- `src/memory/storage.zig` — SQLite backend

### Tools, Plugins, Security
- `src/tools/` — Tool registry, policy engine
- `src/plugins/` — Manifest parsing, plugin API, loader
- `src/sandbox/` — Docker Engine API, security policies, workspace
- `src/security/` — Path traversal detection, binary allowlist
- `src/hooks/` — Event registry
- `src/cron/` — Cron expression parser, job scheduler

### CLI & UI
- `src/cli/main.zig` — 13 commands, all wired to real data
- `src/cli/output.zig` — ANSI colors, JSON/plain/rich output modes
- `src/ui/` — Web UI state, RPC, views, embedded static files
- `src/media/` — Message chunking, per-channel markdown rendering

## What's Working End-to-End

1. **`zclaw gateway run`** — Starts HTTP + WebSocket server with config validation, signal handling
2. **`zclaw agent -m "hello"`** — Routes through real provider API, returns AI response, saves session
3. **Telegram bot** — Set `TELEGRAM_BOT_TOKEN`, bot polls for messages and replies via AI
4. **Discord bot** — Set `DISCORD_BOT_TOKEN` + `DISCORD_CHANNEL_ID`, polls and replies
5. **Slack bot** — Set `SLACK_BOT_TOKEN`, receives events via `/slack/events` webhook
6. **`zclaw models`** — Shows 12 providers with API key detection
7. **`zclaw channels list`** — Shows configured channels from environment
8. **`zclaw sessions`** — Lists real session files from disk
9. **`zclaw memory search`** — Indexes memory directory and performs keyword search
10. **`zclaw doctor`** — Real health checks (config, API keys, file access)
11. **`zclaw config get/set`** — Reads/writes live config values

## Remaining Gaps (Post-MVP)

| Gap | Description | Priority |
|-----|-------------|----------|
| Voice/audio pipeline | TTS/STT, voice wake | Low |
| Browser control | Chrome integration | Low |
| Mobile nodes | iOS/Android/macOS | Low |
| Canvas (A2UI) | Interactive UI from agent | Low |
| Multi-agent spawning | Subagent creation | Medium |
| Docker sandbox comms | Unix socket protocol | Medium |
| Plugin dynamic loading | std.DynLib integration | Medium |
| Additional channels | WhatsApp, Signal, Matrix (stubs exist) | Medium |

# zclaw

Personal AI assistant gateway. Connects your AI providers to Telegram, Discord, and Slack from a single 769 KB binary.

Zig port of [OpenClaw](https://github.com/openclaw/openclaw).

## Install

Requires [Zig 0.15.2](https://ziglang.org/download/).

```
git clone https://github.com/matiasvillaverde/zclaw.git
cd zclaw
zig build -Doptimize=ReleaseSmall
```

Binary goes to `zig-out/bin/zclaw`.

## Quick start

```
# Set at least one provider key
export ANTHROPIC_API_KEY=sk-ant-...

# Talk to it
./zig-out/bin/zclaw agent -m "what is zig?"

# Or start the gateway with a channel
export TELEGRAM_BOT_TOKEN=123456:ABC...
./zig-out/bin/zclaw gateway run
```

## Providers

Set the environment variable to enable a provider. Use `--provider <name>` with the agent command.

| Provider | Env var | Default model |
|----------|---------|---------------|
| anthropic | `ANTHROPIC_API_KEY` | claude-sonnet-4 |
| openai | `OPENAI_API_KEY` | gpt-4o |
| gemini | `GEMINI_API_KEY` | gemini-2.0-flash |
| groq | `GROQ_API_KEY` | llama-3.3-70b-versatile |
| deepseek | `DEEPSEEK_API_KEY` | deepseek-chat |
| mistral | `MISTRAL_API_KEY` | mistral-large-latest |
| xai | `XAI_API_KEY` | grok-2 |
| openrouter | `OPENROUTER_API_KEY` | claude-sonnet-4 |
| ollama | (none) | llama3 |

## Channels

| Channel | Env vars | How it works |
|---------|----------|--------------|
| Telegram | `TELEGRAM_BOT_TOKEN` | Long-polling |
| Discord | `DISCORD_BOT_TOKEN`, `DISCORD_CHANNEL_ID` | REST polling |
| Slack | `SLACK_BOT_TOKEN` | Webhook at `/slack/events` |

All channels route messages through the agent runtime and reply in the same thread.

## CLI

```
zclaw gateway run          # start the gateway server
zclaw agent -m "hello"     # one-shot agent turn
zclaw models               # list providers and API key status
zclaw channels list        # show configured channels
zclaw sessions             # list conversation sessions
zclaw memory search <q>    # search indexed memory
zclaw doctor               # check config, keys, files
zclaw config get/set       # read/write config values
zclaw --json <command>     # JSON output for scripting
```

## Numbers

| | |
|-|-|
| Binary | 769 KB (ReleaseSmall, arm64) |
| Startup | ~2 ms |
| Tests | 3,841 |
| Source files | 74 |
| Providers | 9 (3 native + 6 OpenAI-compatible) |

## Config

Reads from `~/.openclaw/openclaw.json`. Compatible with OpenClaw config format. Supports JSON5 (comments, trailing commas).

Sessions are saved to `~/.openclaw/sessions/`.

## Development

```
zig build test --summary all    # run all tests
zig build                       # debug build
zig build -Doptimize=ReleaseFast  # optimized build
```

## License

MIT

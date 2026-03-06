# Symphony × Claude Code

A fork of [OpenAI's Symphony](https://github.com/openai/symphony) that replaces Codex with **Claude Code** as the coding agent runtime.

Symphony turns project work into isolated, autonomous implementation runs — it monitors a Linear board, spawns coding agents for each issue, and manages the full lifecycle (workspace setup → implementation → PR creation → status updates). This fork swaps the agent backend from OpenAI Codex to Anthropic's Claude Code CLI.

> [!WARNING]
> This is an experimental fork for testing in trusted environments.

## What's Changed

| Component | Original (Codex) | This Fork (Claude Code) |
|---|---|---|
| **Agent Runtime** | `codex app-server` (JSON-RPC over stdio) | `claude -p --output-format stream-json` |
| **Session Model** | Persistent session (start → run turns → stop) | Process-per-turn (each invocation is independent) |
| **Communication** | JSON-RPC 2.0 (`initialize`, `thread/start`, `turn/start`) | Stream JSON lines (`system/init`, `assistant`, `tool_use`, `result`) |
| **Permissions** | Codex sandbox policies | `--dangerously-skip-permissions` flag |

### Key Files

- **`elixir/lib/symphony_elixir/claude_code.ex`** — New module that spawns Claude Code CLI and parses stream-json output
- **`elixir/lib/symphony_elixir/agent_runner.ex`** — Updated from session-based to process-based agent execution
- **`elixir/lib/symphony_elixir/config.ex`** — Default command changed to Claude Code CLI
- **`elixir/lib/symphony_elixir/orchestrator.ex`** — Token extraction updated for Claude Code's flat usage format

### Known Issues

- **Dashboard**: Claude Code's `-p` mode stdout doesn't flow through Erlang Port pipes correctly. The terminal/web dashboard shows stale token counts and events. Core orchestration works fine.

## Running

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [mise](https://mise.jdx.dev/) for Erlang/Elixir toolchain
- A Linear project with issues to process

### Setup

```bash
cd elixir
mise trust && mise install
mix deps.get
```

Configure `WORKFLOW.md` with your Linear project slug and API key, then:

```bash
source .env && export LINEAR_API_KEY
mix escript.build
./bin/symphony ./WORKFLOW.md --port 4000 \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

For full setup details, see the original [elixir/README.md](elixir/README.md).

## Upstream

Based on [openai/symphony](https://github.com/openai/symphony) — see the original repo for the full spec (`SPEC.md`) and architecture documentation.

## License

This project is licensed under the [Apache License 2.0](LICENSE).

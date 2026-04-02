# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ollama Chat is a real-time web chat interface for local Ollama LLMs, built with Elixir/Phoenix LiveView. Chat state lives in-memory and browser localStorage. LLM memory backed by PostgreSQL + pgvector. Single-route app serving a LiveView chat UI over WebSocket.

## Commands

```bash
mix setup              # Install deps + build assets (first-time setup)
mix phx.server         # Start dev server at localhost:4000
mix test               # Run all tests
mix test path/to/test.exs           # Run single test file
mix test --failed      # Re-run previously failed tests
mix precommit          # Run before committing: compile (warnings-as-errors) + format + test + dep check
mix format             # Format code
mix compile --warnings-as-errors    # Check for warnings
./scripts/postgres-docker.sh start   # Start PostgreSQL container
./scripts/postgres-docker.sh stop    # Stop PostgreSQL container
./scripts/postgres-docker.sh status  # Check container status
mix ecto.create            # Create database
mix ecto.migrate           # Run migrations
mix ecto.reset             # Drop + recreate + migrate
```

## Architecture

**Request flow:** Browser → WebSocket → `ChatLive` (LiveView) → `OllamaClient` → Ollama API (localhost:11434)

**Key modules:**
- `OllamaChat.OllamaClient` (`lib/ollama_chat/ollama_client.ex`) — HTTP client for Ollama API: streaming chat, model listing, health checks, auto-start via `OLLAMA_START_COMMAND`
- `OllamaChatWeb.ChatLive` (`lib/ollama_chat_web/live/chat_live.ex`) — Main LiveView handling all UI state, message streaming, model selection, error recovery. Uses Phoenix streams for the message list
- `OllamaChat.MCPClient` (`lib/ollama_chat/mcp_client.ex`) — GenServer managing MCP server connections, tool discovery, execution, crash recovery, and dynamic server management (add/remove/update/toggle)
- `OllamaChat.MCPConfig` (`lib/ollama_chat/mcp_config.ex`) — JSON file-based persistence for MCP server configurations. Loads/saves to `~/.config/ollama_chat/mcp_servers.json` (or `MCP_CONFIG_PATH`), merges with app config defaults
- `OllamaChatWeb.CoreComponents` — Reusable UI components including `<.icon>`, `<.input>`, `<.button>`
- `OllamaChat.Memory` (`lib/ollama_chat/memory.ex`) — Context module for LLM memory: CRUD operations, text search, retrieval ranking. Backed by PostgreSQL + pgvector
- `OllamaChat.Memory.Entry` (`lib/ollama_chat/memory/entry.ex`) — Ecto schema for memory entries (facts, preferences, context, episodic)
- `OllamaChat.Repo` (`lib/ollama_chat/repo.ex`) — Ecto Repo for PostgreSQL with pgvector type support

**Streaming flow:** User sends message → spawned process calls `OllamaClient.chat_stream/3` → NDJSON chunks sent as `{:stream_chunk, id, content}` messages to LiveView → accumulated and rendered in real-time → `{:stream_done, id}` finalizes

**Error recovery:** Connection failures trigger `ensure_ollama_running/0` which can auto-start Ollama, then retry with a 2-second delay.

**Environment variables** (see `.env.example`): `OLLAMA_BASE_URL`, `OLLAMA_DEFAULT_MODEL`, `OLLAMA_START_COMMAND`, `OLLAMA_KILL_COMMAND`, `OLLAMA_CHAT_PORT`, `OLLAMA_HEALTH_CHECK_ENABLED`, `OLLAMA_HEALTH_CHECK_INTERVAL_MS`, `MCP_CONFIG_PATH`, `OLLAMA_CHAT_DB_USERNAME`, `OLLAMA_CHAT_DB_PASSWORD`, `OLLAMA_CHAT_DB_HOSTNAME`, `OLLAMA_CHAT_DB_NAME`, `OLLAMA_CHAT_DB_PORT`, `OLLAMA_CHAT_DB_URL`

## Development Guidelines

See @AGENTS.md for full Phoenix, Elixir, LiveView, and testing conventions.

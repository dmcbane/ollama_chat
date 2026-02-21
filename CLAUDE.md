# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ollama Chat is a real-time web chat interface for local Ollama LLMs, built with Elixir/Phoenix LiveView. No database — state lives in-memory and browser localStorage. Single-route app serving a LiveView chat UI over WebSocket.

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
```

## Architecture

**Request flow:** Browser → WebSocket → `ChatLive` (LiveView) → `OllamaClient` → Ollama API (localhost:11434)

**Key modules:**
- `OllamaChat.OllamaClient` (`lib/ollama_chat/ollama_client.ex`) — HTTP client for Ollama API: streaming chat, model listing, health checks, auto-start via `OLLAMA_START_COMMAND`
- `OllamaChatWeb.ChatLive` (`lib/ollama_chat_web/live/chat_live.ex`) — Main LiveView handling all UI state, message streaming, model selection, error recovery. Uses Phoenix streams for the message list
- `OllamaChatWeb.CoreComponents` — Reusable UI components including `<.icon>`, `<.input>`, `<.button>`

**Streaming flow:** User sends message → spawned process calls `OllamaClient.chat_stream/3` → NDJSON chunks sent as `{:stream_chunk, id, content}` messages to LiveView → accumulated and rendered in real-time → `{:stream_done, id}` finalizes

**Error recovery:** Connection failures trigger `ensure_ollama_running/0` which can auto-start Ollama, then retry with a 2-second delay.

**Environment variables** (see `.env.example`): `OLLAMA_BASE_URL`, `OLLAMA_DEFAULT_MODEL`, `OLLAMA_START_COMMAND`, `OLLAMA_CHAT_PORT`

## Development Guidelines

See @AGENTS.md for full Phoenix, Elixir, LiveView, and testing conventions.

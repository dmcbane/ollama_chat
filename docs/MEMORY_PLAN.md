# LLM Memory Implementation Plan

> Persistent, semantic memory for Ollama Chat — backed by PostgreSQL + pgvector

## Table of Contents

- [Overview](#overview)
- [Architecture Decision: Built-in + Plugin Hybrid](#architecture-decision-built-in--plugin-hybrid)
- [Memory Types](#memory-types)
- [Database Schema](#database-schema-postgresql--pgvector)
- [Retrieval Algorithm](#retrieval-algorithm)
- [System Prompt Injection](#system-prompt-injection)
- [Built-in Tool Architecture](#built-in-tool-architecture)
- [Phase 1: Foundation (PostgreSQL + Ecto)](#phase-1-foundation-postgresql--ecto--current)
- [Phase 2: Embedding Pipeline](#phase-2-embedding-pipeline)
- [Phase 3: Automatic Retrieval & Injection](#phase-3-automatic-retrieval--injection)
- [Phase 4: Built-in Tool Infrastructure](#phase-4-built-in-tool-infrastructure)
- [Phase 5: Auto-extraction](#phase-5-auto-extraction)
- [Phase 6: Maintenance & Polish](#phase-6-maintenance--polish)
- [Environment Variables](#environment-variables-all-phases)
- [Key Design Decisions](#key-design-decisions)

---

## Overview

Ollama Chat currently has **no database** — all state lives in-memory (GenServers, LiveView assigns) and browser localStorage. This plan adds **persistent, semantic memory** so the LLM can remember facts, preferences, and context across conversations.

### Core Principles

- **Hybrid approach**: automatic retrieval + LLM-managed tools working together
- **Memory is injected into the system prompt** before each turn — the LLM sees relevant memories as context
- **LLM can actively manage memories** via built-in tools (save, search, update, delete)
- **Everything stays local** — embeddings generated via Ollama API, stored in PostgreSQL + pgvector
- **Graceful degradation** — the app continues to work if the database is unavailable

### What Changes

| Before | After |
|--------|-------|
| No persistence | PostgreSQL + pgvector for memory storage |
| Stateless conversations | Memories persist across sessions |
| No embedding support | Ollama embedding API integration |
| MCP tools only | Built-in tools + MCP tools (unified registry) |
| Static system prompt | Dynamic system prompt with injected memories |

---

## Architecture Decision: Built-in + Plugin Hybrid

Memory **must** be a hybrid of built-in engine and tool-based management. Here's why:

### Why Not Pure MCP Plugin?

An MCP-based memory server would work for simple save/search, but falls short:

1. **Automatic retrieval** — Memory needs to be fetched and injected into the system prompt *before* the LLM even sees the user's message. An MCP tool can only be called *by* the LLM, not *before* the LLM.
2. **Conversation lifecycle integration** — Auto-extraction at conversation end, access tracking on retrieval, and embedding generation all require tight coupling with the app's internal event flow.
3. **Performance** — In-process Ecto queries are faster than MCP protocol round-trips for something called on every single message.
4. **Reliability** — Memory is a core feature, not an optional plugin. It shouldn't depend on an external process staying alive.

### The Hybrid Architecture

```
┌─────────────────────────────────────────────────────┐
│                   ChatLive (LiveView)                │
│                                                      │
│  1. User sends message                               │
│  2. Automatic retrieval → inject into system prompt   │
│  3. Send to Ollama (with memory context)              │
│  4. LLM responds, possibly calling memory tools       │
│  5. Tool calls routed to built-in or MCP executor     │
│  6. On conversation end → auto-extract memories       │
└──────────┬────────────────────────┬──────────────────┘
           │                        │
    ┌──────▼──────┐          ┌──────▼──────┐
    │  Memory     │          │  MCP Client │
    │  Engine     │          │  (GenServer)│
    │  (built-in) │          │             │
    │  - Retrieve │          │  - External │
    │  - Store    │          │    tools    │
    │  - Embed    │          │  - External │
    │  - Extract  │          │    servers  │
    └──────┬──────┘          └─────────────┘
           │
    ┌──────▼──────┐
    │ PostgreSQL  │
    │ + pgvector  │
    └─────────────┘
```

- **Storage/retrieval engine**: Built-in (tight integration with conversation lifecycle)
- **Management tools**: Built-in tools (new concept alongside MCP tools)
- **Automatic context injection** happens transparently before each LLM call
- **Active LLM agency** via tool calls lets the LLM decide when to save/search/update

---

## Memory Types

Each memory has a `memory_type` that determines how it's used and displayed:

| Type | Description | Example | Typical Source |
|------|-------------|---------|----------------|
| `fact` | Factual information about the user or their work | "User prefers Elixir" | Auto-extract, LLM explicit |
| `preference` | User preferences for interaction style | "User likes concise answers" | Auto-extract, LLM explicit |
| `context` | Current project or work context | "Working on Ollama Chat project" | LLM explicit, auto-extract |
| `episodic` | What happened in previous conversations | "Last session we debugged MCP connections" | Auto-extract (conversation summaries) |

Memory types serve as organizational categories and influence retrieval weighting — preferences and facts tend to be long-lived, while context and episodic memories may decay faster.

---

## Database Schema (PostgreSQL + pgvector)

### `memories` table

```sql
CREATE TABLE memories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content TEXT NOT NULL,
  memory_type VARCHAR(20) NOT NULL,  -- fact, preference, context, episodic
  category VARCHAR(50),
  importance FLOAT DEFAULT 0.5,      -- 0.0-1.0
  access_count INTEGER DEFAULT 0,
  last_accessed_at TIMESTAMPTZ,
  source VARCHAR(20) NOT NULL,       -- auto_extract, llm_explicit, user_manual
  conversation_id VARCHAR(255),
  embedding vector(768),             -- nomic-embed-text dimensions
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

-- Approximate nearest-neighbor index for fast similarity search
CREATE INDEX memories_embedding_idx ON memories
  USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Supporting indexes
CREATE INDEX memories_type_idx ON memories (memory_type);
CREATE INDEX memories_importance_idx ON memories (importance DESC);
CREATE INDEX memories_last_accessed_idx ON memories (last_accessed_at DESC);
CREATE INDEX memories_source_idx ON memories (source);
```

### `conversation_summaries` table

```sql
CREATE TABLE conversation_summaries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id VARCHAR(255) NOT NULL UNIQUE,
  summary TEXT NOT NULL,
  key_topics TEXT[] DEFAULT '{}',
  embedding vector(768),
  message_count INTEGER DEFAULT 0,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX conversation_summaries_embedding_idx ON conversation_summaries
  USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
```

### Field Reference

| Field | Purpose |
|-------|---------|
| `content` | The actual memory text (human-readable) |
| `memory_type` | Classification: fact, preference, context, episodic |
| `category` | Optional grouping (e.g., "programming", "personal") |
| `importance` | 0.0–1.0 score affecting retrieval priority |
| `access_count` | How many times this memory has been retrieved (for decay/pruning) |
| `last_accessed_at` | When this memory was last used in a prompt |
| `source` | How the memory was created: `auto_extract`, `llm_explicit`, `user_manual` |
| `conversation_id` | Links memory to the conversation where it originated |
| `embedding` | 768-dimensional vector from nomic-embed-text |
| `metadata` | Flexible JSONB for future use (tags, related memory IDs, etc.) |

---

## Retrieval Algorithm

On every user message, before sending to the LLM:

```
1. Generate embedding for user's message
   └── POST /api/embed to Ollama with nomic-embed-text

2. Query memories with hybrid scoring:
   score = (0.60 × semantic_similarity)    -- cosine similarity of embeddings
         + (0.25 × importance)             -- the memory's importance field
         + (0.15 × recency_bonus)          -- decays over time since last access

   recency_bonus = 1.0 / (1.0 + days_since_last_access * 0.1)

3. Take top N results (default: 10, configurable via OLLAMA_MEMORY_MAX_RESULTS)

4. Update access tracking:
   - Increment access_count
   - Set last_accessed_at to now()

5. Format and inject into system prompt
```

### Fallback: Full-Text Search

When embeddings are unavailable (model not pulled, embedding generation fails):

```sql
SELECT *, ts_rank(to_tsvector('english', content), plainto_tsquery('english', $1)) AS rank
FROM memories
WHERE to_tsvector('english', content) @@ plainto_tsquery('english', $1)
ORDER BY rank DESC, importance DESC
LIMIT $2;
```

---

## System Prompt Injection

Retrieved memories are formatted and prepended to the system prompt:

```
## Your Memory
You remember the following from previous interactions:
- User's name is David (high importance · learned Jan 15)
- User is building "Ollama Chat" in Elixir/Phoenix (high · Jan 20)
- User prefers concise, technical answers (medium · Jan 18)

Use this context naturally. Save new memories with memory_save when you learn something important.
You do NOT need to tell the user you're saving a memory unless they ask.
```

### Formatting Rules

- Each memory is a single bullet point
- Importance displayed as: high (≥0.7), medium (0.4–0.69), low (<0.4)
- Date shows when the memory was first created
- Total injection stays within token budget (default: ~500 tokens / 10 memories)
- If no memories match, the section is omitted entirely

---

## Built-in Tool Architecture

### Unified Tool Registry

Currently, all tools come from MCP servers. Memory introduces a new concept: **built-in tools** that execute in-process.

```
Tool Registry
├── Built-in Tools (memory, conversation search, etc.)
│   ├── Discovered at boot
│   ├── Executed in-process via Elixir function calls
│   └── Always available (no external dependencies)
└── MCP Tools (external servers)
    ├── Discovered via MCP protocol
    ├── Executed via ExMCP.Client
    └── Available when servers connected
```

### BuiltinTool Behaviour

```elixir
defmodule OllamaChat.BuiltinTool do
  @doc "The tool name used in tool calls (e.g., 'memory_save')"
  @callback name() :: String.t()

  @doc "Human-readable description for the LLM"
  @callback description() :: String.t()

  @doc "JSON Schema for the tool's parameters"
  @callback parameters_schema() :: map()

  @doc "Execute the tool with the given arguments"
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, String.t()}
end
```

### Memory Tools

| Tool | Description | Arguments |
|------|-------------|-----------|
| `memory_save` | Save a new memory | `content` (required), `memory_type`, `category`, `importance` |
| `memory_search` | Search memories by query | `query` (required), `memory_type`, `limit` |
| `memory_update` | Update an existing memory | `id` (required), `content`, `importance`, `category` |
| `memory_delete` | Delete a memory | `id` (required) |
| `memory_list` | List recent memories | `memory_type`, `limit`, `sort_by` |

### Tool Call Flow

```
LLM output: {"tool_call": {"name": "memory_save", "arguments": {"content": "User prefers dark mode", "memory_type": "preference"}}}
    │
    ▼
ToolResponseParser detects tool_call
    │
    ▼
ToolRouter checks: is "memory_save" a built-in tool?
    ├── YES → BuiltinTools.execute("memory_save", args)
    │         └── OllamaChat.BuiltinTools.Memory.Save.execute(args)
    │             └── Memory.create_memory(args) + generate embedding
    └── NO  → MCPClient.call_tool(server, "memory_save", args)
```

---

## Phase 1: Foundation (PostgreSQL + Ecto) — CURRENT

> **Goal**: Get PostgreSQL running in Docker, Ecto integrated, and basic CRUD for memories working.

This is the most detailed phase since it's being implemented now.

### 1.1 PostgreSQL + pgvector Docker Setup

Adapted from notex_prototype's proven Docker configuration.

#### `Dockerfile.postgres`

PostgreSQL 16 Alpine with pgvector v0.7.4 compiled from source:

```dockerfile
FROM postgres:16-alpine

# Build pgvector extension from source
RUN apk add --no-cache --virtual .build-deps \
      git build-base clang15 llvm15-dev \
    && git clone --branch v0.7.4 https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make OPTFLAGS="" \
    && make install \
    && rm -rf /tmp/pgvector \
    && apk del .build-deps
```

#### `docker-compose.postgres.yml`

Parameterized with environment variables:

```yaml
services:
  postgres:
    build:
      context: .
      dockerfile: Dockerfile.postgres
    container_name: ollama_chat_postgres
    environment:
      POSTGRES_USER: ${OLLAMA_CHAT_DB_USERNAME:-ollama_chat}
      POSTGRES_PASSWORD: ${OLLAMA_CHAT_DB_PASSWORD:-ollama_chat}
      POSTGRES_DB: ${OLLAMA_CHAT_DB_NAME:-ollama_chat_dev}
    ports:
      - "${OLLAMA_CHAT_DB_PORT:-5432}:5432"
    volumes:
      - ${OLLAMA_CHAT_POSTGRES_DATA_DIR:-./priv/postgres_data}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${OLLAMA_CHAT_DB_USERNAME:-ollama_chat}"]
      interval: 5s
      timeout: 5s
      retries: 5
```

#### `scripts/postgres-docker.sh`

Container lifecycle management script:

```bash
#!/bin/bash
# Usage: scripts/postgres-docker.sh {start|stop|status|reset|logs}
#
# Manages the PostgreSQL + pgvector Docker container.
# Supports both Docker and Podman.
```

Commands:
- `start` — Build image (if needed) and start container; wait for healthcheck
- `stop` — Stop container gracefully
- `status` — Show container status and connection info
- `reset` — Stop container, delete data volume, restart fresh
- `logs` — Tail container logs

### 1.2 Elixir Dependencies

Add to `mix.exs`:

```elixir
{:ecto_sql, "~> 3.11"},
{:postgrex, ">= 0.0.0"},
{:phoenix_ecto, "~> 4.5"},
{:pgvector, "~> 0.3.0"}
```

### 1.3 Repo Module

```elixir
defmodule OllamaChat.Repo do
  use Ecto.Repo,
    otp_app: :ollama_chat,
    adapter: Ecto.Adapters.Postgres
end
```

Register custom Postgrex types for pgvector:

```elixir
Postgrex.Types.define(
  OllamaChat.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
```

### 1.4 Database Configuration

#### `config/dev.exs`

```elixir
config :ollama_chat, OllamaChat.Repo,
  username: System.get_env("OLLAMA_CHAT_DB_USERNAME", "ollama_chat"),
  password: System.get_env("OLLAMA_CHAT_DB_PASSWORD", "ollama_chat"),
  hostname: System.get_env("OLLAMA_CHAT_DB_HOSTNAME", "localhost"),
  database: System.get_env("OLLAMA_CHAT_DB_NAME", "ollama_chat_dev"),
  port: String.to_integer(System.get_env("OLLAMA_CHAT_DB_PORT", "5432")),
  types: OllamaChat.PostgrexTypes,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("OLLAMA_CHAT_DB_POOL_SIZE", "10"))
```

#### `config/test.exs`

```elixir
config :ollama_chat, OllamaChat.Repo,
  username: System.get_env("OLLAMA_CHAT_DB_USERNAME", "ollama_chat"),
  password: System.get_env("OLLAMA_CHAT_DB_PASSWORD", "ollama_chat"),
  hostname: System.get_env("OLLAMA_CHAT_DB_HOSTNAME", "localhost"),
  database: "ollama_chat_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: String.to_integer(System.get_env("OLLAMA_CHAT_DB_PORT", "5432")),
  types: OllamaChat.PostgrexTypes,
  pool: Ecto.Adapters.SQL.Sandbox
```

#### `config/runtime.exs` (production)

```elixir
if database_url = System.get_env("OLLAMA_CHAT_DB_URL") do
  config :ollama_chat, OllamaChat.Repo,
    url: database_url,
    types: OllamaChat.PostgrexTypes,
    pool_size: String.to_integer(System.get_env("OLLAMA_CHAT_DB_POOL_SIZE", "10"))
end
```

### 1.5 Migrations

#### Migration 1: Enable pgvector extension

```elixir
defmodule OllamaChat.Repo.Migrations.EnablePgvector do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
```

#### Migration 2: Create memories table

```elixir
defmodule OllamaChat.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  def change do
    create table(:memories, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :content, :text, null: false
      add :memory_type, :string, size: 20, null: false
      add :category, :string, size: 50
      add :importance, :float, default: 0.5
      add :access_count, :integer, default: 0
      add :last_accessed_at, :utc_datetime_usec
      add :source, :string, size: 20, null: false
      add :conversation_id, :string, size: 255
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # pgvector column added separately (Ecto doesn't natively support the type)
    execute(
      "ALTER TABLE memories ADD COLUMN embedding vector(768)",
      "ALTER TABLE memories DROP COLUMN embedding"
    )

    create index(:memories, [:memory_type])
    create index(:memories, [:importance])
    create index(:memories, [:last_accessed_at])
    create index(:memories, [:source])

    # IVFFlat index for approximate nearest-neighbor search
    execute(
      "CREATE INDEX memories_embedding_idx ON memories USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)",
      "DROP INDEX IF EXISTS memories_embedding_idx"
    )
  end
end
```

#### Migration 3: Create conversation_summaries table

```elixir
defmodule OllamaChat.Repo.Migrations.CreateConversationSummaries do
  use Ecto.Migration

  def change do
    create table(:conversation_summaries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :conversation_id, :string, size: 255, null: false
      add :summary, :text, null: false
      add :key_topics, {:array, :string}, default: []
      add :message_count, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE conversation_summaries ADD COLUMN embedding vector(768)",
      "ALTER TABLE conversation_summaries DROP COLUMN embedding"
    )

    create unique_index(:conversation_summaries, [:conversation_id])

    execute(
      "CREATE INDEX conversation_summaries_embedding_idx ON conversation_summaries USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)",
      "DROP INDEX IF EXISTS conversation_summaries_embedding_idx"
    )
  end
end
```

### 1.6 Ecto Schema

```elixir
defmodule OllamaChat.Memory.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @memory_types ~w(fact preference context episodic)
  @sources ~w(auto_extract llm_explicit user_manual)

  schema "memories" do
    field :content, :string
    field :memory_type, :string
    field :category, :string
    field :importance, :float, default: 0.5
    field :access_count, :integer, default: 0
    field :last_accessed_at, :utc_datetime_usec
    field :source, :string
    field :conversation_id, :string
    field :embedding, Pgvector.Ecto.Vector
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:content, :memory_type, :category, :importance, :source,
                     :conversation_id, :embedding, :metadata])
    |> validate_required([:content, :memory_type, :source])
    |> validate_inclusion(:memory_type, @memory_types)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0,
                                    less_than_or_equal_to: 1.0)
  end
end
```

### 1.7 Memory Context Module

```elixir
defmodule OllamaChat.Memory do
  @moduledoc """
  Context module for memory CRUD operations.
  """

  import Ecto.Query
  alias OllamaChat.Repo
  alias OllamaChat.Memory.Entry

  def create_memory(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
  end

  def get_memory(id), do: Repo.get(Entry, id)

  def update_memory(%Entry{} = entry, attrs) do
    entry
    |> Entry.changeset(attrs)
    |> Repo.update()
  end

  def delete_memory(%Entry{} = entry), do: Repo.delete(entry)

  def list_memories(opts \\ []) do
    Entry
    |> maybe_filter_type(opts[:memory_type])
    |> maybe_limit(opts[:limit])
    |> order_by([m], desc: m.importance, desc: m.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [m], m.memory_type == ^type)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)
end
```

### 1.8 Application & Supervision Changes

Add `OllamaChat.Repo` to the supervision tree in `application.ex`:

```elixir
children = [
  OllamaChat.Repo,  # Add before other children
  # ... existing children
]
```

### 1.9 Mix Setup Integration

Update `mix.exs` aliases:

```elixir
defp aliases do
  [
    setup: [
      "deps.get",
      "cmd scripts/postgres-docker.sh start",
      "ecto.setup",
      "assets.setup",
      "assets.build"
    ],
    "ecto.setup": ["ecto.create", "ecto.migrate"],
    "ecto.reset": ["ecto.drop", "ecto.setup"],
    # ... existing aliases
  ]
end
```

### 1.10 Phase 1 Deliverables Checklist

- [ ] `Dockerfile.postgres` — PostgreSQL 16 + pgvector 0.7.4
- [ ] `docker-compose.postgres.yml` — parameterized container config
- [ ] `scripts/postgres-docker.sh` — container lifecycle management
- [ ] Mix dependencies added (ecto_sql, postgrex, phoenix_ecto, pgvector)
- [ ] `OllamaChat.Repo` module with custom Postgrex types
- [ ] Database config for dev/test/prod environments
- [ ] Migration: enable pgvector extension
- [ ] Migration: create memories table with vector column + indexes
- [ ] Migration: create conversation_summaries table
- [ ] `OllamaChat.Memory.Entry` Ecto schema
- [ ] `OllamaChat.Memory` context module (CRUD operations)
- [ ] Repo added to supervision tree
- [ ] `mix setup` alias updated with container start + ecto.setup
- [ ] `.env.example` updated with OLLAMA_CHAT_DB_* variables
- [ ] Tests for Memory context (CRUD, validations)

---

## Phase 2: Embedding Pipeline

> **Goal**: Generate vector embeddings for memories using Ollama's embedding API, enabling semantic similarity search.

### 2.1 OllamaClient Embedding Support

Add `/api/embed` endpoint support to the existing `OllamaClient`:

```elixir
def generate_embedding(text, opts \\ []) do
  model = opts[:model] || embedding_model()
  body = %{"model" => model, "input" => text}

  case post("/api/embed", body) do
    {:ok, %{"embeddings" => [embedding | _]}} -> {:ok, embedding}
    {:ok, response} -> {:error, {:unexpected_response, response}}
    {:error, reason} -> {:error, reason}
  end
end

defp embedding_model do
  System.get_env("OLLAMA_EMBEDDING_MODEL", "nomic-embed-text")
end
```

### 2.2 Embeddings Module

```elixir
defmodule OllamaChat.Embeddings do
  @moduledoc """
  Generates and manages vector embeddings for memory content.
  """

  def generate_and_store(memory_entry) do
    case OllamaChat.OllamaClient.generate_embedding(memory_entry.content) do
      {:ok, embedding} ->
        OllamaChat.Memory.update_memory(memory_entry, %{embedding: embedding})
      {:error, reason} ->
        Logger.warning("Failed to generate embedding: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def ensure_embedding_model_available do
    # Pull nomic-embed-text if not already available
  end
end
```

### 2.3 Automatic Embedding on Create/Update

When a memory is created or its content is updated, automatically generate an embedding in an async Task:

```elixir
def create_memory_with_embedding(attrs) do
  with {:ok, entry} <- create_memory(attrs) do
    Task.start(fn -> Embeddings.generate_and_store(entry) end)
    {:ok, entry}
  end
end
```

### 2.4 Full-Text Search Fallback

When embeddings are unavailable (model not pulled, Ollama down, etc.), fall back to PostgreSQL full-text search:

```elixir
def search_by_text(query, opts \\ []) do
  limit = opts[:limit] || 10

  from(m in Entry,
    where: fragment(
      "to_tsvector('english', ?) @@ plainto_tsquery('english', ?)",
      m.content, ^query
    ),
    order_by: [desc: fragment(
      "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
      m.content, ^query
    )],
    limit: ^limit
  )
  |> Repo.all()
end
```

### 2.5 Phase 2 Deliverables

- [ ] `OllamaClient.generate_embedding/2` — calls Ollama `/api/embed`
- [ ] `OllamaChat.Embeddings` module — generate, store, cache
- [ ] `OLLAMA_EMBEDDING_MODEL` config (default: `nomic-embed-text`)
- [ ] Auto-generate embeddings on memory create/update
- [ ] Full-text search fallback when embeddings unavailable
- [ ] Batch embedding generation for existing memories (backfill task)
- [ ] Tests with mocked Ollama embedding responses

---

## Phase 3: Automatic Retrieval & Injection

> **Goal**: Before each LLM call, automatically retrieve relevant memories and inject them into the system prompt.

### 3.1 Retrieval Pipeline

Before each `chat_stream` call in `ChatLive`:

```elixir
defp retrieve_and_inject_memories(socket, user_message) do
  if memory_enabled?() do
    case OllamaChat.Memory.retrieve_relevant(user_message, max_results()) do
      {:ok, memories} ->
        inject_into_system_prompt(socket, memories)
      {:error, _reason} ->
        socket  # Graceful degradation
    end
  else
    socket
  end
end
```

### 3.2 Hybrid Scoring Query

```elixir
def retrieve_relevant(query_text, limit \\ 10) do
  with {:ok, query_embedding} <- OllamaClient.generate_embedding(query_text) do
    results =
      from(m in Entry,
        select: %{
          entry: m,
          similarity: fragment(
            "1 - (embedding <=> ?::vector)",
            ^Pgvector.new(query_embedding)
          )
        },
        where: not is_nil(m.embedding),
        order_by: [desc: fragment(
          """
          (0.60 * (1 - (embedding <=> ?::vector)))
          + (0.25 * importance)
          + (0.15 * (1.0 / (1.0 + EXTRACT(EPOCH FROM (NOW() - COALESCE(last_accessed_at, inserted_at))) / 86400.0 * 0.1)))
          """,
          ^Pgvector.new(query_embedding)
        )],
        limit: ^limit
      )
      |> Repo.all()

    # Update access tracking
    update_access_tracking(results)

    {:ok, results}
  end
end
```

### 3.3 System Prompt Builder Extension

Extend the existing system prompt construction to include a memory section:

```elixir
defp build_system_prompt(base_prompt, memories) do
  memory_section = format_memory_section(memories)

  if memory_section != "" do
    base_prompt <> "\n\n" <> memory_section
  else
    base_prompt
  end
end

defp format_memory_section([]), do: ""
defp format_memory_section(memories) do
  items =
    memories
    |> Enum.map(&format_memory_item/1)
    |> Enum.join("\n")

  """
  ## Your Memory
  You remember the following from previous interactions:
  #{items}

  Use this context naturally. Save new memories with memory_save when you learn something important.
  You do NOT need to tell the user you're saving a memory unless they ask.
  """
end

defp format_memory_item(%{entry: entry}) do
  importance_label = importance_to_label(entry.importance)
  date = Calendar.strftime(entry.inserted_at, "%b %-d")
  "- #{entry.content} (#{importance_label} · #{date})"
end

defp importance_to_label(i) when i >= 0.7, do: "high importance"
defp importance_to_label(i) when i >= 0.4, do: "medium importance"
defp importance_to_label(_), do: "low importance"
```

### 3.4 Token Budget Awareness

Ensure memory injection doesn't consume too many tokens:

```elixir
@default_max_memories 10
@default_max_memory_tokens 500  # ~approximate

defp trim_to_token_budget(memories, max_tokens \\ @default_max_memory_tokens) do
  memories
  |> Enum.reduce_while({[], 0}, fn memory, {acc, tokens} ->
    estimated = estimate_tokens(memory.entry.content)
    if tokens + estimated <= max_tokens do
      {:cont, {[memory | acc], tokens + estimated}}
    else
      {:halt, {acc, tokens}}
    end
  end)
  |> elem(0)
  |> Enum.reverse()
end
```

### 3.5 Graceful Degradation

The memory system must never block or break the core chat functionality:

- Database connection failure → skip memory retrieval, log warning
- Embedding generation failure → fall back to text search
- Text search failure → proceed without memories
- Slow query → configurable timeout (default: 2 seconds)

### 3.6 Phase 3 Deliverables

- [ ] `Memory.retrieve_relevant/2` — hybrid scoring retrieval
- [ ] System prompt builder extended with memory section
- [ ] Token budget management for memory injection
- [ ] Access tracking (count + timestamp) updated on retrieval
- [ ] `OLLAMA_MEMORY_ENABLED` toggle (default: `true`)
- [ ] `OLLAMA_MEMORY_MAX_RESULTS` config (default: `10`)
- [ ] Graceful degradation at every failure point
- [ ] Integration with `ChatLive` message handling flow
- [ ] Tests for retrieval, scoring, prompt building, degradation

---

## Phase 4: Built-in Tool Infrastructure

> **Goal**: Create a unified tool system that supports both built-in tools (memory) and MCP tools, then implement memory management tools.

### 4.1 BuiltinTool Behaviour

```elixir
defmodule OllamaChat.BuiltinTool do
  @moduledoc """
  Behaviour for tools that execute in-process (as opposed to MCP tools
  that execute via external server processes).
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters_schema() :: map()
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, String.t()}
end
```

### 4.2 Built-in Tool Registry

```elixir
defmodule OllamaChat.BuiltinTools.Registry do
  @moduledoc """
  Discovers and manages all available built-in tools.
  """

  @tools [
    OllamaChat.BuiltinTools.Memory.Save,
    OllamaChat.BuiltinTools.Memory.Search,
    OllamaChat.BuiltinTools.Memory.Update,
    OllamaChat.BuiltinTools.Memory.Delete,
    OllamaChat.BuiltinTools.Memory.List
  ]

  def list_tools, do: @tools

  def get_tool(name) do
    Enum.find(@tools, fn tool -> tool.name() == name end)
  end

  def builtin_tool?(name) do
    get_tool(name) != nil
  end

  def tool_schemas do
    Enum.map(@tools, fn tool ->
      %{
        "name" => tool.name(),
        "description" => tool.description(),
        "parameters" => tool.parameters_schema()
      }
    end)
  end
end
```

### 4.3 Tool Router

Unify routing of tool calls to either built-in or MCP executors:

```elixir
defmodule OllamaChat.ToolRouter do
  alias OllamaChat.BuiltinTools.Registry, as: BuiltinRegistry

  def route_tool_call(name, arguments) do
    if BuiltinRegistry.builtin_tool?(name) do
      tool = BuiltinRegistry.get_tool(name)
      tool.execute(arguments)
    else
      # Delegate to MCP
      OllamaChat.MCPClient.call_tool(name, arguments)
    end
  end
end
```

### 4.4 Generalize Prompt Builder

Rename/extend `MCPPromptBuilder` → `ToolPromptBuilder` to describe ALL available tools:

```elixir
defmodule OllamaChat.ToolPromptBuilder do
  def build_tool_descriptions do
    builtin_tools = BuiltinTools.Registry.tool_schemas()
    mcp_tools = MCPClient.list_tools()

    all_tools = builtin_tools ++ mcp_tools
    format_tools_for_prompt(all_tools)
  end
end
```

### 4.5 Memory Tool Implementations

Example — `memory_save`:

```elixir
defmodule OllamaChat.BuiltinTools.Memory.Save do
  @behaviour OllamaChat.BuiltinTool

  @impl true
  def name, do: "memory_save"

  @impl true
  def description do
    "Save a new memory about the user or conversation. Use this when you learn something " <>
    "important about the user's preferences, facts about them, or context about their work."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "required" => ["content"],
      "properties" => %{
        "content" => %{"type" => "string", "description" => "The memory content to save"},
        "memory_type" => %{
          "type" => "string",
          "enum" => ["fact", "preference", "context", "episodic"],
          "default" => "fact",
          "description" => "The type of memory"
        },
        "category" => %{"type" => "string", "description" => "Optional category"},
        "importance" => %{
          "type" => "number", "minimum" => 0.0, "maximum" => 1.0, "default" => 0.5,
          "description" => "Importance score (0.0-1.0)"
        }
      }
    }
  end

  @impl true
  def execute(args) do
    attrs = %{
      content: args["content"],
      memory_type: args["memory_type"] || "fact",
      category: args["category"],
      importance: args["importance"] || 0.5,
      source: "llm_explicit"
    }

    case OllamaChat.Memory.create_memory_with_embedding(attrs) do
      {:ok, entry} ->
        {:ok, "Memory saved: \"#{entry.content}\" (#{entry.memory_type}, importance: #{entry.importance})"}
      {:error, changeset} ->
        {:error, "Failed to save memory: #{inspect(changeset.errors)}"}
    end
  end
end
```

### 4.6 Generalize Response Parser

Update `MCPResponseParser` (or create `ToolResponseParser`) to route tool calls through `ToolRouter` instead of directly to `MCPClient`.

### 4.7 Phase 4 Deliverables

- [ ] `OllamaChat.BuiltinTool` behaviour module
- [ ] `OllamaChat.BuiltinTools.Registry` — tool discovery and lookup
- [ ] `OllamaChat.ToolRouter` — routes to built-in or MCP executor
- [ ] `ToolPromptBuilder` — unified tool descriptions for all tools
- [ ] `BuiltinTools.Memory.Save` implementation
- [ ] `BuiltinTools.Memory.Search` implementation
- [ ] `BuiltinTools.Memory.Update` implementation
- [ ] `BuiltinTools.Memory.Delete` implementation
- [ ] `BuiltinTools.Memory.List` implementation
- [ ] Response parser generalized for built-in tool routing
- [ ] Toast notifications when LLM saves a memory (toggleable)
- [ ] Tests for each memory tool
- [ ] Tests for tool routing (built-in vs MCP)
- [ ] Integration test: LLM output → tool call → memory saved → memory retrieved

---

## Phase 5: Auto-extraction

> **Goal**: Automatically extract memories from conversations and generate conversation summaries.

### 5.1 Conversation End Detection

Trigger extraction when:
- User starts a new conversation (previous one had 5+ messages)
- User explicitly ends a conversation
- Session timeout (configurable)

### 5.2 Extraction Prompt

Send the conversation to the LLM with an extraction prompt:

```
Review this conversation and extract key information worth remembering.
For each item, provide:
- content: the fact/preference/context to remember
- memory_type: one of "fact", "preference", "context", "episodic"
- importance: 0.0-1.0

Focus on:
- Personal facts about the user (name, role, preferences)
- Technical context (projects, tools, languages they use)
- Interaction preferences (communication style, detail level)
- Key outcomes or decisions made

Respond as JSON array:
[{"content": "...", "memory_type": "...", "importance": 0.0}]
```

### 5.3 Deduplication

Before saving extracted memories, check for semantic duplicates:

```elixir
def deduplicate(new_memory_text, threshold \\ 0.85) do
  case generate_embedding(new_memory_text) do
    {:ok, embedding} ->
      existing = find_similar(embedding, threshold)
      if Enum.empty?(existing) do
        :new
      else
        {:duplicate, hd(existing)}
      end
    {:error, _} ->
      :new  # When in doubt, save it
  end
end
```

### 5.4 Conversation Summarization

Generate and store a summary of each conversation:

```elixir
def summarize_conversation(conversation_id, messages) do
  prompt = "Summarize this conversation in 2-3 sentences. What were the main topics and outcomes?"

  case OllamaClient.chat([%{role: "user", content: format_messages(messages) <> "\n\n" <> prompt}]) do
    {:ok, summary} ->
      %{
        conversation_id: conversation_id,
        summary: summary,
        key_topics: extract_topics(summary),
        message_count: length(messages)
      }
      |> create_conversation_summary()
    {:error, reason} ->
      Logger.warning("Failed to summarize conversation: #{inspect(reason)}")
      {:error, reason}
  end
end
```

### 5.5 Phase 5 Deliverables

- [ ] Conversation end detection logic
- [ ] Extraction prompt template
- [ ] `OllamaChat.Memory.Extractor` module
- [ ] Semantic deduplication against existing memories
- [ ] `OllamaChat.Memory.ConversationSummary` schema and context
- [ ] Conversation summarization pipeline
- [ ] Configurable extraction aggressiveness (number of messages threshold)
- [ ] Background Task for extraction (non-blocking)
- [ ] Tests for extraction, deduplication, summarization

---

## Phase 6: Maintenance & Polish

> **Goal**: Long-term memory health, user-facing management UI, and production hardening.

### 6.1 Importance Decay

Memories that are never accessed should gradually fade:

```elixir
def decay_importance do
  # Run periodically (e.g., daily via scheduled task)
  from(m in Entry,
    where: m.last_accessed_at < ago(30, "day") or is_nil(m.last_accessed_at),
    where: m.importance > 0.1,
    update: [set: [importance: fragment("GREATEST(importance * 0.95, 0.1)")]]
  )
  |> Repo.update_all([])
end
```

### 6.2 Duplicate Detection & Consolidation

Periodic scan for semantically similar memories that should be merged:

```elixir
def find_duplicates(threshold \\ 0.90) do
  # Find pairs of memories with high cosine similarity
  # Present to user for review, or auto-merge if confidence is high
end
```

### 6.3 Memory Limits & Pruning

Configurable maximum number of memories:

- Default: 1000 memories
- When limit reached, prune lowest-scoring memories
- Score = importance × recency × access_frequency
- Never prune `user_manual` source memories without explicit consent

### 6.4 User-Facing Memory Browser

Add a "Memories" tab to the Settings dialog:

- List all memories with search/filter
- View memory details (content, type, importance, source, dates)
- Edit memory content and importance
- Delete individual memories
- Bulk operations (delete all, export)
- Memory statistics (total count, by type, by source)

### 6.5 Export/Import

```elixir
def export_memories(format \\ :json) do
  memories = list_memories([])
  case format do
    :json -> Jason.encode!(memories)
    :csv -> format_as_csv(memories)
  end
end

def import_memories(data, format \\ :json) do
  # Parse, validate, deduplicate, and insert
end
```

### 6.6 Memory Statistics

Available in settings or sidebar:

- Total memories by type
- Memories created this week/month
- Most accessed memories
- Storage usage
- Average importance score

### 6.7 Phase 6 Deliverables

- [ ] Importance decay scheduled task
- [ ] Duplicate detection and consolidation
- [ ] Memory limits and pruning logic
- [ ] Memory browser UI in Settings dialog (LiveView component)
- [ ] Memory search/filter in browser
- [ ] Edit/delete individual memories from UI
- [ ] Export memories as JSON
- [ ] Import memories from JSON
- [ ] Memory statistics display
- [ ] Production hardening (connection pooling, query timeouts, error rates)
- [ ] Documentation for users

---

## Environment Variables (All Phases)

| Variable | Default | Phase | Purpose |
|---|---|---|---|
| `OLLAMA_CHAT_DB_USERNAME` | `ollama_chat` | 1 | Database username |
| `OLLAMA_CHAT_DB_PASSWORD` | `ollama_chat` | 1 | Database password |
| `OLLAMA_CHAT_DB_HOSTNAME` | `localhost` | 1 | Database hostname |
| `OLLAMA_CHAT_DB_NAME` | `ollama_chat_dev` | 1 | Database name |
| `OLLAMA_CHAT_DB_PORT` | `5432` | 1 | Database port |
| `OLLAMA_CHAT_DB_POOL_SIZE` | `10` | 1 | Connection pool size |
| `OLLAMA_CHAT_DB_URL` | _(none)_ | 1 | Production database URL (overrides individual params) |
| `OLLAMA_CHAT_POSTGRES_DATA_DIR` | `./priv/postgres_data` | 1 | Docker volume path for PostgreSQL data |
| `OLLAMA_EMBEDDING_MODEL` | `nomic-embed-text` | 2 | Ollama model for generating embeddings |
| `OLLAMA_MEMORY_MAX_RESULTS` | `10` | 3 | Maximum memories retrieved per query |
| `OLLAMA_MEMORY_ENABLED` | `true` | 3 | Enable/disable the entire memory system |

---

## Key Design Decisions

### 1. Embedding Model: nomic-embed-text

- **768 dimensions** — good balance of quality and performance
- **Runs locally via Ollama** — no external API calls, keeps everything on-device
- **Fast inference** — suitable for real-time retrieval on every message
- **Good quality** — competitive with cloud embedding models for this use case

### 2. PostgreSQL Required

- **pgvector is production-grade** — battle-tested vector similarity search
- **Aligns with adding real persistence** — the app is growing beyond in-memory state
- **Docker/Podman managed** — easy setup, no system-level installation required
- **Rich query capabilities** — JSONB, full-text search, array operations, all useful for memory

### 3. Memory Visibility

- **Toast notifications** when the LLM saves a memory (default: on, toggleable)
- **No inline announcements** — the LLM should NOT tell the user "I'm saving this memory" unless asked
- **Memory browser** in Settings for full transparency and control

### 4. Auto-extraction Trigger

- **After conversations with 5+ messages** — short exchanges rarely contain memorable info
- **Runs asynchronously** — doesn't block the next conversation
- **Configurable threshold** — users can adjust or disable

### 5. Token Budget

- **Default: 10 memories / ~500 tokens** for memory context section
- **Configurable** — power users can increase, constrained environments can decrease
- **Prioritized by hybrid score** — most relevant memories always included first

### 6. Container Management

- **Docker and Podman supported** via `scripts/postgres-docker.sh`
- **Integrated into `mix setup`** — first-time setup automatically starts the container
- **Data persisted to local directory** — survives container restarts
- **Parameterized via environment variables** — easy to customize ports, credentials, paths
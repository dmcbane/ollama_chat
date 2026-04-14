# Memory System User Guide

Ollama Chat includes a persistent memory system that allows the LLM to remember facts, preferences, and context across conversations. This guide explains how it works, how to use it, and how to configure it.

---

## Table of Contents

1. [Overview](#overview)
2. [How Memory Works](#how-memory-works)
3. [Memory Types](#memory-types)
4. [Memory Sources](#memory-sources)
5. [Using Memory in Chat](#using-memory-in-chat)
   - [Customizing via System Prompt](#customizing-memory-behavior-via-system-prompt)
6. [Memory Browser](#memory-browser)
7. [Importing and Exporting](#importing-and-exporting)
8. [Automatic Maintenance](#automatic-maintenance)
9. [Configuration](#configuration)
10. [Privacy and Data](#privacy-and-data)
11. [Troubleshooting](#troubleshooting)

---

## Overview

The memory system gives the LLM a persistent knowledge store that survives across conversations. Instead of starting fresh every session, the LLM can recall:

- Facts you've shared ("My name is Alice, I work at Acme Corp")
- Your preferences ("I prefer concise answers with code examples")
- Technical context ("I'm building a Phoenix app with pgvector")
- Episodic memories ("Last session we debugged the MCP connection issue")

Memory is stored in PostgreSQL with vector embeddings, enabling **semantic search** — the LLM retrieves the most relevant memories for each message, not just the most recent ones.

---

## How Memory Works

### Retrieval on Every Message

When you send a message, the system:

1. Generates a vector embedding of your message using the configured embedding model
2. Searches stored memories using a hybrid scoring algorithm:
   - **60%** semantic similarity (pgvector cosine distance)
   - **25%** importance score
   - **15%** recency (how recently the memory was accessed)
3. Injects the top-scoring memories into the system prompt as context
4. The LLM sees this context and can respond with awareness of your history

### Automatic Extraction

When you start a new conversation (and the previous one had 5+ messages), the system runs extraction in the background:

1. Sends the completed conversation to the LLM with an extraction prompt
2. The LLM identifies key facts, preferences, and context worth remembering
3. Each candidate is checked for semantic similarity against existing memories to avoid duplicates
4. New unique memories are saved with source `auto_extract`
5. A conversation summary is generated and stored

This happens asynchronously — you can start your next conversation immediately.

### Semantic Deduplication

Before saving any extracted memory, the system generates its embedding and checks for existing memories with cosine distance < 0.15 (approximately ≥85% similarity). Duplicate candidates are silently skipped, keeping the memory store clean.

---

## Memory Types

Each memory is classified into one of four types:

| Type | Description | Examples |
|------|-------------|---------|
| **fact** | Factual information about you or your environment | "User's name is Alice", "User works at Acme Corp" |
| **preference** | How you like things done | "User prefers concise answers", "User dislikes verbose explanations" |
| **context** | Ongoing project or situational context | "User is building a Phoenix app", "User is debugging a pgvector issue" |
| **episodic** | Session-specific memories | "Last session we fixed the MCP connection timeout" |

---

## Memory Sources

| Source | Description |
|--------|-------------|
| **auto_extract** | Automatically extracted from conversations |
| **llm_explicit** | Explicitly saved by the LLM via the `memory_save` tool |
| **user_manual** | Manually created or imported by you |

> **Note:** `user_manual` memories are never automatically pruned, even when the memory limit is reached.

---

## Using Memory in Chat

> **💡 See also:** [System Prompt Guide](SYSTEM_PROMPT_GUIDE.md) — Learn how to customize memory behavior via the system prompt.

### The LLM Saves Memories Automatically

When the LLM encounters something important during a conversation (your name, a preference, project context), it will use the built-in `memory_save` tool to save it immediately. You'll see a toast notification: **"Memory saved"**.

You don't need to do anything special — just chat naturally.

### Telling the LLM What to Remember

You can explicitly ask the LLM to remember something:

> "Remember that I prefer tabs over spaces."

> "Save a note that we're using Elixir 1.19 for this project."

> "Update my name — it's Bob, not Alice."

The LLM will use the appropriate memory tool (`memory_save`, `memory_update`) to act on your request.

### Asking About What's Remembered

> "What do you know about me?"

> "What have you remembered from our conversations?"

> "Do you remember my name?"

The LLM will search its memory store and tell you what it has.

### Correcting or Forgetting Memories

> "Forget that I work at Acme Corp."

> "Update my role — I'm now a senior engineer, not a junior one."

> "Delete everything you know about my old project."

### Customizing Memory Behavior via System Prompt

The **System Prompt** allows you to control how the LLM uses memory tools. By default, Ollama Chat includes instructions that tell the LLM when and how to save memories, but you can customize this behavior.

**To access the System Prompt:**

1. Look for the **System Prompt** collapsible section in the chat interface (near the message input area)
2. Click to expand it
3. Add or modify instructions

**Default memory instructions include:**

- **Search first** — The LLM searches memories at conversation start and when context is needed
- **Save silently** — Memories are saved during conversation without announcing it
- **Choose appropriate types** — Use `fact`, `preference`, `context`, or `episodic` based on the content
- **Set importance correctly** — High (0.8+) for critical info, medium (0.5) for normal, low (0.2) for minor details

**Example customizations:**

*More aggressive saving:*
```
Save memories more frequently, even for small details about my workflow and tools.
```

*More conservative saving:*
```
Only save memories when I explicitly ask you to, or when you learn critical information about me.
```

*Domain-specific focus:*
```
Focus memory on technical decisions, architecture choices, and project constraints.
Ignore personal preferences unless they directly affect code quality.
```

*Importance tuning:*
```
Use high importance (0.8+) for security decisions, architecture patterns, and hard-learned lessons.
Use low importance (0.2-0.4) for anything I can easily look up later.
```

The system prompt is saved per-conversation and persists when you reload the page.

---

## Memory Browser

The Memory Browser is available in **Settings → Memories**. It provides full visibility and control over all stored memories.

### Opening the Memory Browser

1. Click the **Settings** button (⚙) in the sidebar
2. Select the **Memories** tab

### Statistics Panel

At the top of the Memory tab you'll see:

- **Total Memories** — count of all stored entries
- **Avg Importance** — average importance score as a percentage
- **Types Active** — how many distinct memory types have entries

### Searching and Filtering

- **Search box** — full-text search across memory content (uses PostgreSQL ILIKE)
- **Type filter** — filter by `fact`, `preference`, `context`, or `episodic`

Results update as you type (300ms debounce).

### Viewing Memories

Each memory row shows:

- The memory content (up to 2 lines, with truncation)
- A colour-coded type badge:
  - 🔵 Blue — `fact`
  - 🟣 Purple — `preference`
  - 🟡 Yellow — `context`
  - 🟢 Green — `episodic`
- The importance percentage

### Editing a Memory

1. Click the **pencil icon** (✏️) on any memory row
2. Adjust the **Importance** slider (0–100%)
3. Change the **Type** if needed
4. Click **Save** to persist, or **Cancel** to discard

### Deleting a Memory

- Click the pencil icon to open the edit panel, then click **Delete** (with confirmation)
- Or use **Delete All** in the list header to remove all memories at once

---

## Importing and Exporting

### Exporting Memories

1. Open **Settings → Memories**
2. Click **Export** (visible when memories exist)
3. A file `memories_YYYY-MM-DD.json` will be downloaded

The export contains all memories as a JSON array:

```json
[
  {
    "content": "User's name is Alice",
    "memory_type": "fact",
    "importance": 0.9,
    "source": "llm_explicit",
    "category": null,
    "conversation_id": "conv-abc123",
    "access_count": 4,
    "metadata": {},
    "inserted_at": "2026-04-06T10:00:00Z"
  }
]
```

### Importing Memories

1. Open **Settings → Memories**
2. Click **Import memories from JSON** (toggle at the bottom)
3. Paste your JSON array into the textarea
4. Click **Import**

Each imported entry is validated through the normal changeset. Invalid entries (missing required fields, out-of-range importance) are counted as failures but do not block the rest of the import.

**Minimum required fields per entry:**

```json
{ "content": "...", "memory_type": "fact" }
```

Optional fields: `importance` (0.0–1.0, default 0.5), `source` (default `user_manual`), `category`, `conversation_id`, `metadata`.

### Round-Trip Safety

Exported memories can be re-imported without modification. The `source` field is preserved, so previously `auto_extract` or `llm_explicit` memories retain their original source. The `inserted_at` field is informational only — re-imported memories get new timestamps.

---

## Automatic Maintenance

The memory system runs daily maintenance tasks automatically:

### Importance Decay

Memories that haven't been accessed in **30+ days** have their importance reduced by **5%** per maintenance run (multiplied by 0.95), with a floor of **0.1**. This ensures stale, irrelevant memories naturally fade to the bottom of retrieval rankings without being deleted.

Example: A memory with importance 0.8 that isn't accessed for 30 days becomes 0.76 after one run, 0.72 after two runs, and so on — eventually settling at 0.1.

### Memory Pruning

When the total memory count exceeds the configured limit (default: 1,000), the lowest-scored memories are automatically deleted. Scoring factors:

- **Importance** — higher importance = higher score
- **Recency** — recently accessed memories score higher
- **Access frequency** — frequently accessed memories score higher

> **Protected:** Memories with `source: user_manual` are **never** automatically pruned.

### Manual Maintenance

You can trigger maintenance operations immediately from the Memory Browser:

- **Run Decay** — reduces importance of stale memories right now
- **Prune to Limit** — deletes lowest-scored memories if you're over the configured limit

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_MEMORY_ENABLED` | `true` | Enable or disable the entire memory system |
| `OLLAMA_EMBEDDING_MODEL` | `nomic-embed-text` | Ollama model used to generate embeddings |
| `OLLAMA_MEMORY_MAX_RESULTS` | `10` | Maximum memories retrieved per message |

### Application Config Keys

These can be set in `config/dev.exs` or `config/runtime.exs`:

| Key | Default | Description |
|-----|---------|-------------|
| `:memory_enabled` | `true` | Enable/disable memory system |
| `:memory_max_count` | `1_000` | Maximum total memories before pruning |
| `:memory_max_results` | `10` | Max memories retrieved per query |
| `:memory_extraction_min_messages` | `5` | Minimum messages to trigger auto-extraction |
| `:memory_extraction_dedup_threshold` | `0.15` | Cosine distance threshold for dedup (lower = stricter) |
| `:memory_maintenance_interval_ms` | `86_400_000` | Maintenance run interval (default: 24 hours) |
| `:ollama_embedding_model` | `"nomic-embed-text"` | Embedding model name |

### Disabling Memory

Set `OLLAMA_MEMORY_ENABLED=false` in your environment (or in `.env`). When disabled:

- No database connection is attempted
- Memory retrieval is skipped (no context injected)
- Auto-extraction is skipped
- The Memory tab in Settings shows a disabled notice
- All Memory API calls return `{:error, :memory_disabled}`

### Requiring the Embedding Model

The memory system requires the embedding model to be pulled in Ollama:

```bash
ollama pull nomic-embed-text
```

If the embedding model is unavailable, retrieval gracefully falls back to PostgreSQL full-text search (`plainto_tsquery`). Memories are still saved; they just won't have embeddings for semantic search until the model becomes available (use `mix memory.backfill` to generate missing embeddings).

### Backfilling Embeddings

If you've accumulated memories without embeddings (e.g. the embedding model was unavailable), run:

```bash
mix memory.backfill
# With custom batch size:
mix memory.backfill --batch-size 100
```

This generates and stores embeddings for all memories that don't have one yet.

---

## Privacy and Data

### Where Data is Stored

All memories are stored in your local PostgreSQL database. No data is sent to any external service. The embedding model runs locally via Ollama.

### Database Location

By default, the PostgreSQL data directory is `./priv/postgres_data` (Docker volume). See `docker-compose.postgres.yml` for configuration.

### Deleting All Memories

From the Memory Browser: **Settings → Memories → Delete All** (with confirmation).

From the command line:

```bash
# Connect to the database and truncate
psql -U ollama_chat -d ollama_chat_dev -c "TRUNCATE memories;"
```

Or via the Elixir shell:

```elixir
iex -S mix
OllamaChat.Memory.delete_all_memories()
```

---

## Troubleshooting

### Memory tab shows "Memory system is not enabled"

Set `OLLAMA_MEMORY_ENABLED=true` in your `.env` file and restart the server.

### "Memory retrieval: embedding generation failed, falling back to full-text search"

The `nomic-embed-text` model isn't available in Ollama. Pull it with:

```bash
ollama pull nomic-embed-text
```

Retrieval will continue working via full-text search in the meantime.

### Memories aren't being saved automatically

Check that:
1. Memory is enabled (`OLLAMA_MEMORY_ENABLED=true`)
2. PostgreSQL is running (`./scripts/postgres-docker.sh status`)
3. The database has been migrated (`mix ecto.migrate`)
4. The conversation has at least 5 messages (the extraction threshold)

### The LLM doesn't seem to remember things

Possible causes:
- The relevant memory may not have scored highly enough to be retrieved (default: top 10 memories per message)
- The memory may not have been created yet (extraction runs when you start a *new* conversation)
- Increase `OLLAMA_MEMORY_MAX_RESULTS` to retrieve more memories per message

### Import fails with "Invalid JSON"

Ensure your JSON is a valid array:

```json
[
  {"content": "...", "memory_type": "fact"}
]
```

Not an object (`{}`), not a single item without array brackets.

### Duplicate memories appearing

The deduplication threshold (default: 0.15 cosine distance) may be too loose for your content. You can tighten it:

```elixir
# config/dev.exs
config :ollama_chat, :memory_extraction_dedup_threshold, 0.05
```

Lower values are stricter (fewer duplicates saved but may miss genuinely similar memories).

---

## Quick Reference

| Action | How |
|--------|-----|
| See what's remembered | Ask the LLM: "What do you know about me?" |
| Save something now | Ask the LLM: "Remember that..." |
| Edit a memory | Settings → Memories → ✏️ |
| Delete a memory | Settings → Memories → ✏️ → Delete |
| Delete all memories | Settings → Memories → Delete All |
| Export memories | Settings → Memories → Export |
| Import memories | Settings → Memories → Import memories from JSON |
| Run decay manually | Settings → Memories → Maintenance → Run Decay |
| Prune excess memories | Settings → Memories → Maintenance → Prune to Limit |
| Backfill embeddings | `mix memory.backfill` |
| Disable memory | `OLLAMA_MEMORY_ENABLED=false` in `.env` |
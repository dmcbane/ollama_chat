defmodule OllamaChat.Memory do
  @moduledoc """
  Context module for managing LLM memory entries.

  Provides CRUD operations, search, and retrieval for the memory system.
  Memory entries are atomic facts, preferences, context, or episodic memories
  that the LLM accumulates from conversations.

  ## Memory Types

  - `:fact` — Factual information ("User's name is David")
  - `:preference` — User preferences ("User prefers concise answers")
  - `:context` — Ongoing context ("Working on Ollama Chat project")
  - `:episodic` — Session-specific ("Last session we debugged MCP connections")

  ## Sources

  - `:auto_extract` — Automatically extracted from conversations
  - `:llm_explicit` — Explicitly saved by the LLM via tool call
  - `:user_manual` — Manually created by the user

  ## Error Handling

  All database operations return explicit `{:ok, result}` or `{:error, reason}` tuples.
  Errors are never swallowed — callers can always distinguish success from failure:

  - `{:error, :memory_disabled}` — memory system is turned off via config
  - `{:error, :database_unavailable}` — database connection failed
  - `{:error, %Ecto.Changeset{}}` — validation failure
  - `{:error, :not_found}` — entry not found

  The bang functions (`create_memory!/1`, `get_memory!/1`) are NOT wrapped — they
  raise on failure as expected, for use in scripts, seeds, and tests.
  """

  import Ecto.Query, warn: false

  alias OllamaChat.Memory.Entry
  alias OllamaChat.Repo

  require Logger

  # ── Availability ────────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the memory system is available (enabled and database reachable).
  """
  def available? do
    enabled?() and database_connected?()
  end

  @doc """
  Returns `true` if the memory system is enabled in configuration.
  """
  def enabled? do
    Application.get_env(:ollama_chat, :memory_enabled, true)
  end

  # ── Create ──────────────────────────────────────────────────────────────────

  @doc """
  Creates a new memory entry.

  Returns `{:ok, entry}` on success, `{:error, changeset}` on validation failure,
  or `{:error, :memory_disabled}` / `{:error, :database_unavailable}` when unavailable.

  ## Examples

      iex> create_memory(%{content: "User prefers Elixir", memory_type: "preference", source: "llm_explicit"})
      {:ok, %Entry{}}

      iex> create_memory(%{content: "", memory_type: "invalid"})
      {:error, %Ecto.Changeset{}}
  """
  def create_memory(attrs) when is_map(attrs) do
    with_db(fn ->
      %Entry{}
      |> Entry.changeset(attrs)
      |> Repo.insert()
      |> tap_ok(fn entry ->
        Logger.info(
          "Memory created: #{entry.id} (#{entry.memory_type}) — #{truncate(entry.content)}"
        )
      end)
    end)
  end

  @doc """
  Creates a memory entry, raising on failure.

  Not wrapped with resilience — raises on database errors. Use in scripts/seeds/tests.
  """
  def create_memory!(attrs) when is_map(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert!()
  end

  # ── Read ────────────────────────────────────────────────────────────────────

  @doc """
  Gets a single memory entry by ID.

  Returns `{:ok, entry}` if found, `{:ok, nil}` if not found,
  or `{:error, reason}` when unavailable.
  """
  def get_memory(id) when is_binary(id) do
    with_db(fn -> {:ok, Repo.get(Entry, id)} end)
  end

  @doc """
  Gets a single memory entry by ID, raising if not found.

  Not wrapped with resilience — raises on database errors. Use in scripts/seeds/tests.
  """
  def get_memory!(id) when is_binary(id) do
    Repo.get!(Entry, id)
  end

  @doc """
  Lists all memory entries, ordered by importance (descending) then recency.

  Returns `{:ok, [entries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — Maximum entries to return (default: 50)
  - `:offset` — Offset for pagination (default: 0)
  - `:memory_type` — Filter by type ("fact", "preference", "context", "episodic")
  - `:category` — Filter by category
  - `:source` — Filter by source ("auto_extract", "llm_explicit", "user_manual")
  - `:min_importance` — Minimum importance threshold (0.0–1.0)
  """
  def list_memories(opts \\ []) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, 50)
      offset = Keyword.get(opts, :offset, 0)

      result =
        Entry
        |> apply_filters(opts)
        |> order_by([m], desc: m.importance, desc: m.updated_at)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()

      {:ok, result}
    end)
  end

  @doc """
  Returns the total count of memory entries, with optional filters.

  Returns `{:ok, count}` on success or `{:error, reason}` when unavailable.

  Accepts the same filter options as `list_memories/1`.
  """
  def count_memories(opts \\ []) do
    with_db(fn ->
      result =
        Entry
        |> apply_filters(opts)
        |> Repo.aggregate(:count)

      {:ok, result}
    end)
  end

  # ── Update ──────────────────────────────────────────────────────────────────

  @doc """
  Updates a memory entry's content, type, category, importance, or metadata.

  Returns `{:ok, entry}` on success, `{:error, changeset}` on validation failure,
  or `{:error, reason}` when unavailable.

  ## Examples

      iex> update_memory(entry, %{content: "Updated fact", importance: 0.9})
      {:ok, %Entry{}}
  """
  def update_memory(%Entry{} = entry, attrs) when is_map(attrs) do
    with_db(fn ->
      entry
      |> Entry.update_changeset(attrs)
      |> Repo.update()
      |> tap_ok(fn entry ->
        Logger.info("Memory updated: #{entry.id} — #{truncate(entry.content)}")
      end)
    end)
  end

  @doc """
  Records that a memory was accessed during retrieval.

  Increments `access_count` and updates `last_accessed_at`.
  Returns `{:ok, entry}` on success or `{:error, reason}` when unavailable.
  """
  def touch_memory(%Entry{} = entry) do
    with_db(fn ->
      entry
      |> Entry.access_changeset()
      |> Repo.update()
    end)
  end

  @doc """
  Batch-touch multiple memories (used after retrieval).

  More efficient than touching one at a time — performs a single UPDATE query.
  Returns `{:ok, {count, nil}}` on success or `{:error, reason}` when unavailable.
  """
  def touch_memories([]), do: {:ok, {0, nil}}

  def touch_memories(memory_ids) when is_list(memory_ids) do
    with_db(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        Entry
        |> where([m], m.id in ^memory_ids)
        |> Repo.update_all(inc: [access_count: 1], set: [last_accessed_at: now])

      {:ok, result}
    end)
  end

  @doc """
  Increases importance of a memory (reinforcement through repeated mention).

  Importance is clamped to 1.0.
  Returns `{:ok, entry}` on success or `{:error, reason}` when unavailable.
  """
  def reinforce_memory(%Entry{} = entry, boost \\ 0.1) do
    new_importance = min(entry.importance + boost, 1.0)
    update_memory(entry, %{importance: new_importance})
  end

  # ── Delete ──────────────────────────────────────────────────────────────────

  @doc """
  Deletes a memory entry.

  Returns `{:ok, entry}` on success or `{:error, reason}` when unavailable.
  """
  def delete_memory(%Entry{} = entry) do
    with_db(fn ->
      Repo.delete(entry)
      |> tap_ok(fn entry ->
        Logger.info("Memory deleted: #{entry.id} — #{truncate(entry.content)}")
      end)
    end)
  end

  @doc """
  Deletes a memory entry by ID.

  Returns `{:ok, entry}` on success, `{:error, :not_found}` if not found,
  or `{:error, :memory_disabled}` / `{:error, :database_unavailable}` when unavailable.
  """
  def delete_memory_by_id(id) when is_binary(id) do
    with {:ok, entry} <- get_memory(id) do
      if entry do
        delete_memory(entry)
      else
        {:error, :not_found}
      end
    end
  end

  @doc """
  Deletes all memories. Use with caution.

  Returns `{:ok, count}` on success or `{:error, reason}` when unavailable.
  """
  def delete_all_memories do
    with_db(fn ->
      {count, _} = Repo.delete_all(Entry)
      Logger.info("Deleted all #{count} memories")
      {:ok, count}
    end)
  end

  # ── Search ──────────────────────────────────────────────────────────────────

  @doc """
  Searches memories by text content using PostgreSQL ILIKE.

  This is the keyword-based fallback search used when embeddings are not
  available. For semantic search, see Phase 2 (embedding pipeline).

  Returns `{:ok, [entries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  Accepts the same filter options as `list_memories/1` plus:
  - `:limit` — Maximum results (default: 10)
  """
  def search_by_text(query_text, opts \\ []) when is_binary(query_text) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, 10)
      pattern = "%#{sanitize_like(query_text)}%"

      result =
        Entry
        |> where([m], ilike(m.content, ^pattern))
        |> apply_filters(opts)
        |> order_by([m], desc: m.importance, desc: m.updated_at)
        |> limit(^limit)
        |> Repo.all()

      {:ok, result}
    end)
  end

  @doc """
  Retrieves the most relevant memories for a given context.

  In Phase 1, this uses importance + recency ranking.
  In Phase 2+, this will use semantic similarity via pgvector embeddings.

  Returns `{:ok, [entries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — Maximum memories to retrieve (default: 10)
  - `:memory_type` — Filter by type
  - `:min_importance` — Minimum importance threshold
  """
  def retrieve_relevant(opts \\ []) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, 10)

      result =
        Entry
        |> apply_filters(opts)
        |> order_by([m],
          desc: m.importance,
          desc: m.last_accessed_at,
          desc: m.updated_at
        )
        |> limit(^limit)
        |> Repo.all()

      {:ok, result}
    end)
  end

  # ── Formatting ──────────────────────────────────────────────────────────────

  @doc """
  Formats a list of memory entries for injection into the system prompt.

  Returns `nil` if there are no memories to inject.

  This function does not touch the database — it formats already-retrieved entries.
  """
  def format_for_prompt([]), do: nil

  def format_for_prompt(memories) when is_list(memories) do
    memory_lines = Enum.map_join(memories, "\n", &format_memory_line/1)

    """
    ## Your Memory
    You remember the following from previous interactions:

    #{memory_lines}

    Use this context naturally in your responses. If you learn something \
    important about the user or the conversation context, use the memory_save \
    tool to remember it. If a memory seems wrong or outdated, use memory_update \
    or memory_delete to correct it.
    You do NOT need to tell the user you're saving a memory unless they ask.\
    """
  end

  # ── Statistics ──────────────────────────────────────────────────────────────

  @doc """
  Returns summary statistics about stored memories.

  Returns `{:ok, stats_map}` on success or `{:error, reason}` when unavailable.
  """
  def stats do
    with_db(fn ->
      total = Repo.aggregate(Entry, :count)

      type_counts =
        Entry
        |> group_by([m], m.memory_type)
        |> select([m], {m.memory_type, count(m.id)})
        |> Repo.all()
        |> Map.new()

      source_counts =
        Entry
        |> group_by([m], m.source)
        |> select([m], {m.source, count(m.id)})
        |> Repo.all()
        |> Map.new()

      avg_importance =
        case Repo.aggregate(Entry, :avg, :importance) do
          nil -> 0.0
          %Decimal{} = avg -> Decimal.to_float(avg) |> Float.round(2)
          avg when is_float(avg) -> Float.round(avg, 2)
        end

      {:ok,
       %{
         total: total,
         by_type: type_counts,
         by_source: source_counts,
         average_importance: avg_importance
       }}
    end)
  end

  # ── Private Helpers ─────────────────────────────────────────────────────────

  # Unified wrapper for all database operations. The inner function must return
  # an {:ok, _} | {:error, _} tuple. This wrapper NEVER swallows errors —
  # callers always know whether the operation succeeded or failed, and why.
  defp with_db(fun) when is_function(fun, 0) do
    if enabled?() do
      fun.()
    else
      {:error, :memory_disabled}
    end
  rescue
    e in [DBConnection.ConnectionError] ->
      Logger.error("Memory database unavailable: #{Exception.message(e)}")
      {:error, :database_unavailable}
  end

  defp database_connected? do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_by(:memory_type, Keyword.get(opts, :memory_type))
    |> maybe_filter_by(:category, Keyword.get(opts, :category))
    |> maybe_filter_by(:source, Keyword.get(opts, :source))
    |> maybe_filter_min_importance(Keyword.get(opts, :min_importance))
  end

  defp maybe_filter_by(query, _field, nil), do: query
  defp maybe_filter_by(query, :memory_type, value), do: where(query, [m], m.memory_type == ^value)
  defp maybe_filter_by(query, :category, value), do: where(query, [m], m.category == ^value)
  defp maybe_filter_by(query, :source, value), do: where(query, [m], m.source == ^value)

  defp maybe_filter_min_importance(query, nil), do: query

  defp maybe_filter_min_importance(query, min) when is_number(min) do
    where(query, [m], m.importance >= ^min)
  end

  defp format_memory_line(%Entry{} = memory) do
    importance_label =
      cond do
        memory.importance >= 0.8 -> "high importance"
        memory.importance >= 0.5 -> "medium importance"
        true -> "low importance"
      end

    date_label =
      if memory.inserted_at do
        Calendar.strftime(memory.inserted_at, "%b %-d")
      else
        "unknown date"
      end

    "- #{memory.content} (#{importance_label} · #{memory.memory_type} · learned #{date_label})"
  end

  defp truncate(text, max \\ 80) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…"
    else
      text
    end
  end

  defp sanitize_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp tap_ok({:ok, value}, fun) do
    fun.(value)
    {:ok, value}
  end

  defp tap_ok(error, _fun), do: error
end

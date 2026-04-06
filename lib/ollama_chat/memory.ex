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

  alias OllamaChat.Memory.ConversationSummary
  alias OllamaChat.Memory.Entry
  alias OllamaChat.OllamaClient
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

  @doc """
  Creates a memory entry and asynchronously generates an embedding.

  Returns `{:ok, entry}` immediately. The embedding is generated in a background
  Task and will be available on subsequent reads.

  ## Options

  - `:embedding_fn` — Override the embedding generation function (for testing)
  """
  def create_memory_with_embedding(attrs, opts \\ []) do
    with {:ok, entry} <- create_memory(attrs) do
      embedding_fn = Keyword.get(opts, :embedding_fn)

      Task.start(fn ->
        if embedding_fn do
          case embedding_fn.(entry.content) do
            {:ok, embedding} ->
              OllamaChat.Embeddings.store_embedding(entry, embedding)

            {:error, reason} ->
              Logger.warning(
                "Failed to generate embedding for memory #{entry.id}: #{inspect(reason)}"
              )
          end
        else
          OllamaChat.Embeddings.generate_and_store(entry, opts)
        end
      end)

      {:ok, entry}
    end
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

  @default_max_memory_tokens 500

  @doc """
  Retrieves the most relevant memories for a given query using hybrid scoring.

  Combines semantic similarity (via pgvector embeddings), importance, and recency
  to score and rank memories. Falls back to full-text search if embedding generation
  fails, then gracefully degrades to an empty list on further failures.

  Updates access tracking (count + timestamp) for all returned memories.

  Returns `{:ok, [entries]}` on success, or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — Maximum memories to retrieve (default: `OLLAMA_MEMORY_MAX_RESULTS` env or 10)
  - `:memory_type` — Filter by type
  - `:min_importance` — Minimum importance threshold
  - `:embedding_fn` — Override embedding generation `(text -> {:ok, vec} | {:error, reason})` (for testing)
  """
  def retrieve_relevant(query_text, opts) when is_binary(query_text) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, memory_max_results())
      embedding_fn = Keyword.get(opts, :embedding_fn, &OllamaClient.generate_embedding/1)

      entries =
        case embedding_fn.(query_text) do
          {:ok, query_embedding} ->
            do_hybrid_query(Pgvector.new(query_embedding), limit, opts)

          {:error, reason} ->
            Logger.warning(
              "Memory retrieval: embedding generation failed (#{inspect(reason)}), " <>
                "falling back to full-text search"
            )

            do_fulltext_query(query_text, limit, opts)
        end

      do_update_access_tracking(entries)
      {:ok, trim_to_token_budget(entries)}
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

  @doc """
  Searches memories using PostgreSQL full-text search with ranking.

  Uses `to_tsvector` and `plainto_tsquery` for natural language search
  with relevance ranking via `ts_rank`. This is more effective than ILIKE
  for multi-word queries and provides relevance scoring.

  Returns `{:ok, [entries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — Maximum results (default: 10)
  - Plus all filter options from `list_memories/1`
  """
  def search_by_fulltext(query_text, opts \\ []) when is_binary(query_text) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, 10)

      result =
        Entry
        |> where(
          [m],
          fragment(
            "to_tsvector('english', ?) @@ plainto_tsquery('english', ?)",
            m.content,
            ^query_text
          )
        )
        |> apply_filters(opts)
        |> order_by(
          [m],
          desc:
            fragment(
              "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
              m.content,
              ^query_text
            )
        )
        |> limit(^limit)
        |> Repo.all()

      {:ok, result}
    end)
  end

  @doc """
  Searches memories by semantic similarity using pgvector cosine distance.

  Requires a pre-computed query embedding vector. Only searches memories
  that have embeddings. Results are ordered by similarity (closest first).

  Returns `{:ok, [entries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — Maximum results (default: 10)
  - Plus all filter options from `list_memories/1`
  """
  def search_by_similarity(query_embedding, opts \\ []) when is_list(query_embedding) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, 10)
      vector = Pgvector.new(query_embedding)

      result =
        Entry
        |> where([m], not is_nil(m.embedding))
        |> apply_filters(opts)
        |> order_by([m], asc: fragment("? <=> ?", m.embedding, ^vector))
        |> limit(^limit)
        |> Repo.all()

      {:ok, result}
    end)
  end

  @doc """
  Like `search_by_similarity/2` but includes cosine distance scores.

  Returns `{:ok, [{entry, distance}]}` where distance is a float (0.0 = identical).
  """
  def search_by_similarity_with_scores(query_embedding, opts \\ [])
      when is_list(query_embedding) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, 10)
      vector = Pgvector.new(query_embedding)

      result =
        Entry
        |> where([m], not is_nil(m.embedding))
        |> apply_filters(opts)
        |> select([m], {m, fragment("? <=> ?", m.embedding, ^vector)})
        |> order_by([m], asc: fragment("? <=> ?", m.embedding, ^vector))
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

  # ── Conversation Summaries ──────────────────────────────────────────────────

  @doc """
  Creates or updates a conversation summary (upsert by `conversation_id`).

  If a summary already exists for the given `conversation_id`, its `summary`,
  `key_topics`, `message_count`, and `updated_at` fields are replaced.

  Returns `{:ok, summary}` on success, `{:error, changeset}` on validation
  failure, or `{:error, reason}` when unavailable.
  """
  def create_conversation_summary(attrs) when is_map(attrs) do
    with_db(fn ->
      %ConversationSummary{}
      |> ConversationSummary.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:summary, :key_topics, :message_count, :updated_at]},
        conflict_target: :conversation_id
      )
      |> tap_ok(fn s ->
        Logger.info("Conversation summary stored: conversation=#{s.conversation_id}")
      end)
    end)
  end

  @doc """
  Gets a conversation summary by `conversation_id`.

  Returns `{:ok, summary}` if found, `{:ok, nil}` if not found,
  or `{:error, reason}` when unavailable.
  """
  def get_conversation_summary(conversation_id) when is_binary(conversation_id) do
    with_db(fn ->
      {:ok, Repo.get_by(ConversationSummary, conversation_id: conversation_id)}
    end)
  end

  @doc """
  Lists conversation summaries ordered by most recently created first.

  Returns `{:ok, [summaries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — Maximum entries to return (default: 50)
  - `:offset` — Offset for pagination (default: 0)
  """
  def list_conversation_summaries(opts \\ []) do
    with_db(fn ->
      limit = Keyword.get(opts, :limit, 50)
      offset = Keyword.get(opts, :offset, 0)

      result =
        ConversationSummary
        |> order_by([cs], desc: cs.inserted_at)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()

      {:ok, result}
    end)
  end

  # ── Maintenance ─────────────────────────────────────────────────────────────

  @doc """
  Decays the importance of memories that have not been accessed in 30+ days.

  Applies a 5% reduction per run (multiplied by 0.95), floored at 0.1.
  Intended to be called periodically (e.g. daily) by `Memory.Manager`.

  Returns `{:ok, count}` (entries updated) or `{:error, reason}`.
  """
  def decay_importance do
    with_db(fn ->
      thirty_days_ago =
        DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)

      {count, _} =
        Entry
        |> where([m], m.importance > 0.1)
        |> where([m], is_nil(m.last_accessed_at) or m.last_accessed_at < ^thirty_days_ago)
        |> update([m], set: [importance: fragment("GREATEST(? * 0.95, 0.1)", m.importance)])
        |> Repo.update_all([])

      Logger.info("Decayed importance for #{count} stale memories")
      {:ok, count}
    end)
  end

  @doc """
  Finds pairs of semantically similar memories using pgvector cosine distance.

  Only considers entries that have embeddings stored. Returns at most 50 pairs
  ordered by distance (closest first).

  `threshold` is a cosine distance (0.0 = identical, 2.0 = opposite).
  Default 0.10 corresponds to ≥90% cosine similarity.

  Returns `{:ok, [{entry1, entry2, distance}]}` or `{:error, reason}`.
  """
  def find_duplicates(threshold \\ 0.10) do
    with_db(fn ->
      result =
        Entry
        |> where([m1], not is_nil(m1.embedding))
        |> join(:inner, [m1], m2 in Entry,
          on: fragment("? < ?", m1.id, m2.id) and not is_nil(m2.embedding)
        )
        |> where([m1, m2], fragment("(? <=> ?)", m1.embedding, m2.embedding) < ^threshold)
        |> select([m1, m2], {m1, m2, fragment("(? <=> ?)", m1.embedding, m2.embedding)})
        |> order_by([m1, m2], asc: fragment("(? <=> ?)", m1.embedding, m2.embedding))
        |> limit(50)
        |> Repo.all()

      {:ok, result}
    end)
  end

  @doc """
  Deletes the lowest-scored memories when the total count exceeds `max_count`.

  Scoring formula: `importance × recency_factor × ln(access_count + 1)`.
  `user_manual` memories are never pruned automatically.

  `max_count` defaults to the `:memory_max_count` app config key (default 1000).

  Returns `{:ok, deleted_count}` or `{:error, reason}`.
  """
  def prune_to_limit(max_count \\ nil) do
    with_db(fn ->
      limit = max_count || Application.get_env(:ollama_chat, :memory_max_count, 1_000)
      current_count = Repo.aggregate(Entry, :count)

      if current_count <= limit do
        {:ok, 0}
      else
        to_prune = current_count - limit

        # Fetch prunable entries, compute scores in Elixir to avoid Postgrex
        # timestamptz parameter-binding ambiguity in SQL fragments.
        now = DateTime.utc_now()

        prunable_ids =
          Entry
          |> where([m], m.source != "user_manual")
          |> Repo.all()
          |> Enum.sort_by(fn m ->
            ref_time = m.last_accessed_at || m.inserted_at
            days_old = DateTime.diff(now, ref_time, :second) / 86_400.0
            recency = 1.0 / (1.0 + days_old)
            m.importance * recency * :math.log(m.access_count + 2.0)
          end)
          |> Enum.take(to_prune)
          |> Enum.map(& &1.id)

        {deleted, _} = Repo.delete_all(from(m in Entry, where: m.id in ^prunable_ids))
        Logger.info("Pruned #{deleted} memories (was #{current_count}, limit: #{limit})")
        {:ok, deleted}
      end
    end)
  end

  @doc """
  Exports all memory entries as a JSON string.

  Returns `{:ok, json_string}` or `{:error, reason}`.

  The JSON is a list of objects with fields:
  `content`, `memory_type`, `category`, `importance`, `source`,
  `conversation_id`, `access_count`, `metadata`, `inserted_at`.
  """
  def export_memories(format \\ :json)

  def export_memories(:json) do
    with_db(fn ->
      entries = Repo.all(from(m in Entry, order_by: [asc: m.inserted_at]))

      data =
        Enum.map(entries, fn m ->
          %{
            content: m.content,
            memory_type: m.memory_type,
            category: m.category,
            importance: m.importance,
            source: m.source,
            conversation_id: m.conversation_id,
            access_count: m.access_count,
            metadata: m.metadata,
            inserted_at: DateTime.to_iso8601(m.inserted_at)
          }
        end)

      {:ok, Jason.encode!(data)}
    end)
  end

  def export_memories(format) do
    {:error, {:unsupported_format, format}}
  end

  @doc """
  Imports memory entries from a JSON string.

  Parses the JSON, validates each entry via the normal changeset, and inserts
  all valid records. Invalid items are counted as errors, not silently dropped.

  Returns `{:ok, %{imported: n, failed: n, errors: [...]}}` or `{:error, reason}`.

  ## Options
  - `:embedding_fn` — Override embedding generation for newly imported entries.
  """
  def import_memories(json_data, opts \\ []) when is_binary(json_data) do
    with_db(fn ->
      case Jason.decode(json_data) do
        {:ok, items} when is_list(items) ->
          {imported, failed, errors} =
            Enum.reduce(items, {0, 0, []}, fn item, {ok_count, err_count, errs} ->
              attrs = %{
                content: Map.get(item, "content", ""),
                memory_type: Map.get(item, "memory_type", "fact"),
                category: Map.get(item, "category"),
                importance: Map.get(item, "importance", 0.5),
                source: Map.get(item, "source", "user_manual"),
                conversation_id: Map.get(item, "conversation_id"),
                metadata: Map.get(item, "metadata", %{})
              }

              case create_memory(attrs) do
                {:ok, entry} ->
                  Task.start(fn -> OllamaChat.Embeddings.generate_and_store(entry, opts) end)
                  {ok_count + 1, err_count, errs}

                {:error, reason} ->
                  {ok_count, err_count + 1, [reason | errs]}
              end
            end)

          Logger.info("Memory import: #{imported} imported, #{failed} failed")
          {:ok, %{imported: imported, failed: failed, errors: Enum.reverse(errors)}}

        {:ok, _} ->
          {:error, {:invalid_format, "Expected a JSON array"}}

        {:error, reason} ->
          {:error, {:json_decode_error, reason}}
      end
    end)
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

  # ── Phase 3: Hybrid Retrieval Helpers ────────────────────────────────────────

  # Hybrid scoring query: 60% semantic similarity + 25% importance + 15% recency.
  # Only considers entries that have an embedding stored.
  defp do_hybrid_query(vector, limit, opts) do
    Entry
    |> apply_filters(opts)
    |> where([m], not is_nil(m.embedding))
    |> order_by(
      [m],
      desc:
        fragment(
          "(0.60 * (1.0 - (? <=> ?))) + (0.25 * ?) + (0.15 * (1.0 / (1.0 + EXTRACT(EPOCH FROM (NOW() - COALESCE(?, ?))) / 86400.0 * 0.1)))",
          m.embedding,
          ^vector,
          m.importance,
          m.last_accessed_at,
          m.inserted_at
        )
    )
    |> limit(^limit)
    |> Repo.all()
  rescue
    e ->
      Logger.warning(
        "Memory hybrid query failed: #{Exception.message(e)}, falling back to full-text search"
      )

      []
  end

  # Full-text fallback used when embedding generation fails.
  defp do_fulltext_query(query_text, limit, opts) do
    Entry
    |> where(
      [m],
      fragment(
        "to_tsvector('english', ?) @@ plainto_tsquery('english', ?)",
        m.content,
        ^query_text
      )
    )
    |> apply_filters(opts)
    |> order_by(
      [m],
      desc:
        fragment(
          "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
          m.content,
          ^query_text
        )
    )
    |> limit(^limit)
    |> Repo.all()
  rescue
    e ->
      Logger.warning("Memory full-text query failed: #{Exception.message(e)}")
      []
  end

  # Updates access_count and last_accessed_at for a list of retrieved entries.
  # Best-effort: errors are logged and silently ignored.
  defp do_update_access_tracking([]), do: :ok

  defp do_update_access_tracking(entries) do
    ids = Enum.map(entries, & &1.id)
    _ = touch_memories(ids)
    :ok
  end

  # Trims memories to fit within an approximate token budget.
  # Uses a rough estimate of 1 token ≈ 4 characters.
  defp trim_to_token_budget(entries, max_tokens \\ @default_max_memory_tokens) do
    entries
    |> Enum.reduce_while({[], 0}, fn entry, {acc, tokens} ->
      estimated = div(String.length(entry.content), 4) + 1

      if tokens + estimated <= max_tokens do
        {:cont, {[entry | acc], tokens + estimated}}
      else
        {:halt, {acc, tokens}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Reads the max number of memories to retrieve from application config.
  defp memory_max_results do
    Application.get_env(:ollama_chat, :memory_max_results, 10)
  end
end

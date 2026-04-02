defmodule OllamaChat.Embeddings do
  @moduledoc """
  Generates and manages vector embeddings for memory content.

  Provides functions to store embeddings on memory entries, perform semantic
  similarity search using pgvector's cosine distance operator, and manage
  the embedding lifecycle (backfill, regenerate).

  ## Error Handling

  All functions return `{:ok, result}` or `{:error, reason}` tuples.
  Errors are never swallowed — callers can always distinguish success from failure.

  ## Embedding Model

  The default embedding model is `nomic-embed-text` (768 dimensions).
  Configure via the `:ollama_embedding_model` application env or
  the `OLLAMA_EMBEDDING_MODEL` environment variable.
  """

  import Ecto.Query, warn: false

  alias OllamaChat.Memory
  alias OllamaChat.Memory.Entry
  alias OllamaChat.OllamaClient
  alias OllamaChat.Repo

  require Logger

  @doc """
  Returns the configured embedding model name.

  Defaults to `"nomic-embed-text"` if not configured.
  """
  def embedding_model do
    Application.get_env(:ollama_chat, :ollama_embedding_model, "nomic-embed-text")
  end

  @doc """
  Generates an embedding for the given text using the Ollama embedding API.

  Returns `{:ok, embedding}` where embedding is a list of floats,
  or `{:error, reason}` on failure.

  ## Options

  - `:model` — embedding model to use (default: `embedding_model/0`)
  """
  def generate(text, opts \\ []) when is_binary(text) do
    OllamaClient.generate_embedding(text, opts)
  end

  @doc """
  Stores a pre-computed embedding vector on a memory entry.

  Returns `{:ok, updated_entry}` on success or `{:error, reason}` on failure.

  The embedding must be a non-empty list of numbers matching the expected
  dimensionality (768 for nomic-embed-text).
  """
  def store_embedding(nil, _embedding) do
    {:error, :nil_entry}
  end

  def store_embedding(_entry, []) do
    {:error, :empty_embedding}
  end

  def store_embedding(_entry, nil) do
    {:error, :empty_embedding}
  end

  def store_embedding(%Entry{} = entry, embedding) when is_list(embedding) do
    if Memory.enabled?() do
      vector = Pgvector.new(embedding)

      entry
      |> Ecto.Changeset.change(%{embedding: vector})
      |> Repo.update()
    else
      {:error, :memory_disabled}
    end
  rescue
    e in [DBConnection.ConnectionError] ->
      Logger.error("Memory database unavailable: #{Exception.message(e)}")
      {:error, :database_unavailable}
  end

  @doc """
  Generates an embedding for a memory entry's content and stores it.

  Calls the Ollama embedding API, then updates the entry with the resulting vector.

  Returns `{:ok, updated_entry}` on success or `{:error, reason}` on failure.

  ## Options

  - `:model` — embedding model to use (default: `embedding_model/0`)
  """
  def generate_and_store(%Entry{} = entry, opts \\ []) do
    case generate(entry.content, opts) do
      {:ok, embedding} ->
        store_embedding(entry, embedding)

      {:error, reason} ->
        Logger.warning("Failed to generate embedding for memory #{entry.id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  @doc """
  Performs semantic similarity search using pgvector cosine distance.

  Takes a query embedding vector (list of floats) and returns memory entries
  ordered by similarity (most similar first).

  Returns `{:ok, [entries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — maximum number of results (default: 10)
  - `:min_importance` — minimum importance threshold (default: nil)
  - `:memory_type` — filter by memory type (default: nil)
  """
  def semantic_search(query_embedding, opts \\ [])

  def semantic_search(nil, _opts), do: {:error, :nil_embedding}
  def semantic_search([], _opts), do: {:error, :empty_embedding}

  def semantic_search(query_embedding, opts) when is_list(query_embedding) do
    if Memory.enabled?() do
      limit = Keyword.get(opts, :limit, 10)
      min_importance = Keyword.get(opts, :min_importance)
      memory_type = Keyword.get(opts, :memory_type)

      vector = Pgvector.new(query_embedding)

      query =
        Entry
        |> where([m], not is_nil(m.embedding))
        |> order_by([m], fragment("embedding <=> ?", ^vector))
        |> limit(^limit)

      query =
        if min_importance do
          where(query, [m], m.importance >= ^min_importance)
        else
          query
        end

      query =
        if memory_type do
          where(query, [m], m.memory_type == ^memory_type)
        else
          query
        end

      {:ok, Repo.all(query)}
    else
      {:error, :memory_disabled}
    end
  rescue
    e in [DBConnection.ConnectionError] ->
      Logger.error("Memory database unavailable: #{Exception.message(e)}")
      {:error, :database_unavailable}
  end

  @doc """
  Returns memory entries that do not yet have embeddings.

  Useful for backfilling embeddings on existing memories.

  Returns `{:ok, [entries]}` on success or `{:error, reason}` when unavailable.

  ## Options

  - `:limit` — maximum entries to return (default: 100)
  """
  def entries_without_embeddings(opts \\ []) do
    if Memory.enabled?() do
      limit = Keyword.get(opts, :limit, 100)

      result =
        Entry
        |> where([m], is_nil(m.embedding))
        |> order_by([m], asc: m.inserted_at)
        |> limit(^limit)
        |> Repo.all()

      {:ok, result}
    else
      {:error, :memory_disabled}
    end
  rescue
    e in [DBConnection.ConnectionError] ->
      Logger.error("Memory database unavailable: #{Exception.message(e)}")
      {:error, :database_unavailable}
  end

  @doc """
  Backfills embeddings for all memory entries that don't have one.

  Calls the Ollama embedding API for each entry sequentially.
  Returns `{:ok, %{succeeded: count, failed: count}}` with a summary.

  ## Options

  - `:model` — embedding model to use (default: `embedding_model/0`)
  - `:limit` — max entries to process (default: 100)
  """
  def backfill(opts \\ []) do
    with {:ok, entries} <- entries_without_embeddings(opts) do
      results =
        Enum.reduce(entries, %{succeeded: 0, failed: 0}, fn entry, acc ->
          case generate_and_store(entry, opts) do
            {:ok, _} ->
              %{acc | succeeded: acc.succeeded + 1}

            {:error, reason} ->
              Logger.warning("Backfill failed for memory #{entry.id}: #{inspect(reason)}")
              %{acc | failed: acc.failed + 1}
          end
        end)

      Logger.info(
        "Embedding backfill complete: #{results.succeeded} succeeded, #{results.failed} failed"
      )

      {:ok, results}
    end
  end
end

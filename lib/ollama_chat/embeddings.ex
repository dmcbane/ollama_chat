defmodule OllamaChat.Embeddings do
  @moduledoc """
  Generates and manages vector embeddings for memory content.

  Uses Ollama's embedding API (nomic-embed-text by default) to generate
  768-dimensional vector embeddings stored in PostgreSQL via pgvector.

  ## Testing

  All functions that generate embeddings accept an `:embedding_fn` option
  to override the default `OllamaClient.generate_embedding/1` call.
  This enables unit testing without a running Ollama instance.

  ## Error Handling

  All functions return `{:ok, result}` or `{:error, reason}` tuples.
  Errors are never swallowed — callers can always distinguish success from failure.
  """

  require Logger

  import Ecto.Query, warn: false

  alias OllamaChat.Memory
  alias OllamaChat.Memory.Entry
  alias OllamaChat.OllamaClient
  alias OllamaChat.Repo

  @doc """
  Generates an embedding for the given memory entry's content and stores it.

  Returns `{:ok, updated_entry}` on success or `{:error, reason}` on failure.
  The entry is not modified when embedding generation fails.

  ## Options

  - `:embedding_fn` — Function `(text -> {:ok, embedding} | {:error, reason})`
    to use instead of `OllamaClient.generate_embedding/1` (useful for testing)
  """
  def generate_and_store(%Entry{} = entry, opts \\ []) do
    embedding_fn = Keyword.get(opts, :embedding_fn, &default_embedding_fn/1)

    case embedding_fn.(entry.content) do
      {:ok, embedding} ->
        # Use Ecto.Changeset.change/2 directly because Entry.update_changeset/2
        # does not cast the :embedding field. change/2 sets the field without
        # going through cast, and Repo.update/1 will dump the value through
        # Pgvector.Ecto.Vector appropriately.
        entry
        |> Ecto.Changeset.change(%{embedding: Pgvector.new(embedding)})
        |> Repo.update()

      {:error, reason} ->
        Logger.warning("Failed to generate embedding for memory #{entry.id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  @doc """
  Generates an embedding vector for the given text without storing it.

  Returns `{:ok, embedding}` where embedding is a list of floats,
  or `{:error, reason}` on failure.

  ## Options

  - `:embedding_fn` — Override the embedding generation function
  """
  def generate(text, opts \\ []) do
    embedding_fn = Keyword.get(opts, :embedding_fn, &default_embedding_fn/1)
    embedding_fn.(text)
  end

  @doc """
  Returns `true` if the given memory entry needs an embedding generated.
  """
  def needs_embedding?(%Entry{embedding: nil}), do: true
  def needs_embedding?(%Entry{}), do: false

  @doc """
  Generates embeddings for all memory entries that don't have one yet.

  Processes entries in batches, continuing through failures so that a single
  broken entry does not block the rest. Returns a summary of results.

  Returns `{:ok, %{success: count, failed: count, skipped: count, total: count}}`
  or `{:error, reason}` if the memory system is unavailable.

  ## Options

  - `:batch_size` — Number of entries to process at a time (default: 50)
  - `:embedding_fn` — Override the embedding generation function
  """
  def backfill(opts \\ []) do
    if Memory.enabled?() do
      batch_size = Keyword.get(opts, :batch_size, 50)
      embedding_fn = Keyword.get(opts, :embedding_fn, &default_embedding_fn/1)

      case Memory.count_memories() do
        {:ok, total} ->
          {success, failed, skipped} =
            do_backfill(batch_size, embedding_fn, 0, {0, 0, 0})

          {:ok,
           %{
             success: success,
             failed: failed,
             skipped: skipped,
             total: total
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :memory_disabled}
    end
  end

  @doc """
  Returns the configured embedding model name.

  Defaults to `"nomic-embed-text"` if not configured.
  """
  def embedding_model do
    Application.get_env(:ollama_chat, :ollama_embedding_model, "nomic-embed-text")
  end

  @doc """
  Stores a pre-computed embedding vector on a memory entry.

  Returns `{:ok, updated_entry}` on success or `{:error, reason}` on failure.

  The embedding must be a non-empty list of numbers matching the expected
  dimensionality (768 for nomic-embed-text).
  """
  def store_embedding(nil, _embedding), do: {:error, :nil_entry}
  def store_embedding(_entry, nil), do: {:error, :empty_embedding}
  def store_embedding(_entry, []), do: {:error, :empty_embedding}

  def store_embedding(%Entry{} = entry, embedding) when is_list(embedding) do
    entry
    |> Ecto.Changeset.change(%{embedding: Pgvector.new(embedding)})
    |> Repo.update()
  end

  @doc """
  Checks if the configured embedding model is available in Ollama.

  Returns `true` if the model is listed, `false` otherwise (including
  when the Ollama API is unreachable).
  """
  def embedding_model_available? do
    model = embedding_model()

    case OllamaClient.list_models() do
      {:ok, models} ->
        Enum.any?(models, fn m -> String.starts_with?(m, model) end)

      {:error, _} ->
        false
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp default_embedding_fn(text) do
    OllamaClient.generate_embedding(text)
  end

  defp do_backfill(batch_size, embedding_fn, offset, {success, failed, skipped}) do
    entries =
      Entry
      |> order_by([m], asc: m.inserted_at, asc: m.id)
      |> limit(^batch_size)
      |> offset(^offset)
      |> Repo.all()

    if entries == [] do
      {success, failed, skipped}
    else
      {batch_success, batch_failed, batch_skipped} =
        Enum.reduce(entries, {0, 0, 0}, fn entry, {s, f, sk} ->
          if needs_embedding?(entry) do
            case generate_and_store(entry, embedding_fn: embedding_fn) do
              {:ok, _} -> {s + 1, f, sk}
              {:error, _} -> {s, f + 1, sk}
            end
          else
            {s, f, sk + 1}
          end
        end)

      do_backfill(
        batch_size,
        embedding_fn,
        offset + batch_size,
        {success + batch_success, failed + batch_failed, skipped + batch_skipped}
      )
    end
  end
end

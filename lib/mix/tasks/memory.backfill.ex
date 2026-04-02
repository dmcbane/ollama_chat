defmodule Mix.Tasks.Memory.Backfill do
  @shortdoc "Generate embeddings for memory entries that don't have them"

  @moduledoc """
  Generates vector embeddings for all memory entries that don't already have one.

  This is useful after the initial Phase 2 deployment to backfill embeddings
  for memories created during Phase 1 (before the embedding pipeline existed).

  ## Usage

      mix memory.backfill
      mix memory.backfill --batch-size 100

  ## Options

  - `--batch-size` — Number of entries to process per batch (default: 50)
  """

  use Mix.Task

  require Logger

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [batch_size: :integer])
    batch_size = Keyword.get(opts, :batch_size, 50)

    Mix.shell().info("Starting embedding backfill (batch_size=#{batch_size})...")

    # Check if the embedding model is available
    if OllamaChat.Embeddings.embedding_model_available?() do
      Mix.shell().info(
        "Embedding model '#{OllamaChat.Embeddings.embedding_model()}' is available"
      )
    else
      Mix.shell().error("""
      Warning: Embedding model '#{OllamaChat.Embeddings.embedding_model()}' may not be available.
      Run: ollama pull #{OllamaChat.Embeddings.embedding_model()}
      Continuing anyway in case the model is pulling...
      """)
    end

    case OllamaChat.Embeddings.backfill(batch_size: batch_size) do
      {:ok, stats} ->
        Mix.shell().info("""

        Backfill complete!
          Total entries:  #{stats.total}
          Succeeded:      #{stats.success}
          Failed:         #{stats.failed}
          Skipped:        #{stats.skipped} (already had embeddings)
        """)

      {:error, :memory_disabled} ->
        Mix.shell().error("Error: Memory system is disabled. Set OLLAMA_MEMORY_ENABLED=true")

      {:error, :database_unavailable} ->
        Mix.shell().error("Error: Database is not available. Start PostgreSQL first.")

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
    end
  end
end

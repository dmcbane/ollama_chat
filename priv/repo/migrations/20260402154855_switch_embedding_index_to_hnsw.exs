defmodule OllamaChat.Repo.Migrations.SwitchEmbeddingIndexToHnsw do
  use Ecto.Migration

  def up do
    # Drop the IVFFlat index — it requires training data and has poor recall
    # with small datasets (e.g. < 1000 vectors, or in test sandboxes).
    execute("DROP INDEX IF EXISTS memories_embedding_idx")

    # Replace with HNSW index — no training needed, works correctly with any
    # dataset size, and provides better recall out of the box.
    # m=16 (connections per node) and ef_construction=64 are good defaults
    # for up to ~100k vectors.
    execute("""
    CREATE INDEX memories_embedding_idx ON memories
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE embedding IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS memories_embedding_idx")

    # Restore the original IVFFlat index
    execute("""
    CREATE INDEX memories_embedding_idx ON memories
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
    WHERE embedding IS NOT NULL
    """)
  end
end

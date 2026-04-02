defmodule OllamaChat.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  def up do
    create table(:memories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :content, :text, null: false
      add :memory_type, :string, size: 20, null: false
      add :category, :string, size: 50
      add :importance, :float, default: 0.5, null: false
      add :access_count, :integer, default: 0, null: false
      add :last_accessed_at, :utc_datetime
      add :source, :string, size: 20, null: false
      add :conversation_id, :string, size: 255
      add :embedding, :vector, size: 768
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    # IVFFlat index for fast cosine similarity search on embeddings
    # lists=100 is appropriate for up to ~10k vectors
    # Must use raw SQL because Ecto's index DSL doubles the WITH clause
    execute("""
    CREATE INDEX memories_embedding_idx ON memories
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
    WHERE embedding IS NOT NULL
    """)

    create index(:memories, [:memory_type])
    create index(:memories, [:importance])
    create index(:memories, [:last_accessed_at])
    create index(:memories, [:source])
    create index(:memories, [:conversation_id])
  end

  def down do
    drop table(:memories)
  end
end

defmodule OllamaChat.Memory.Entry do
  @moduledoc """
  Ecto schema for a memory entry.

  Each entry represents an atomic piece of information the LLM has learned
  from conversations — a fact, preference, context, or episodic memory.

  Embeddings are stored as pgvector `vector(768)` columns for semantic
  similarity search (dimensions match nomic-embed-text).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @memory_types ~w(fact preference context episodic)
  @sources ~w(auto_extract llm_explicit user_manual)

  schema "memories" do
    field(:content, :string)
    field(:memory_type, :string)
    field(:category, :string)
    field(:importance, :float, default: 0.5)
    field(:access_count, :integer, default: 0)
    field(:last_accessed_at, :utc_datetime)
    field(:source, :string)
    field(:conversation_id, :string)
    field(:embedding, Pgvector.Ecto.Vector)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @required_fields ~w(content memory_type source)a
  @optional_fields ~w(category importance access_count last_accessed_at
                      conversation_id embedding metadata)a

  @doc """
  Changeset for creating a new memory entry.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:memory_type, @memory_types)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_length(:content, min: 1, max: 10_000)
    |> validate_length(:category, max: 50)
  end

  @doc """
  Changeset for updating access tracking fields after retrieval.
  """
  def access_changeset(entry) do
    entry
    |> change(%{
      access_count: entry.access_count + 1,
      last_accessed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc """
  Changeset for updating an existing memory's content or metadata.
  """
  def update_changeset(entry, attrs) do
    entry
    |> cast(attrs, ~w(content memory_type category importance metadata)a)
    |> validate_required([:content])
    |> validate_inclusion(:memory_type, @memory_types)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_length(:content, min: 1, max: 10_000)
    |> validate_length(:category, max: 50)
  end
end

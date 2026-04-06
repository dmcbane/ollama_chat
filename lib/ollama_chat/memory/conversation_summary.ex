defmodule OllamaChat.Memory.ConversationSummary do
  @moduledoc """
  Ecto schema for a conversation summary.

  Stores a concise summary of a completed conversation, including key topics
  and message count. One summary per conversation (enforced by unique index on
  `conversation_id`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "conversation_summaries" do
    field(:conversation_id, :string)
    field(:summary, :string)
    field(:key_topics, {:array, :string}, default: [])
    field(:message_count, :integer, default: 0)

    timestamps()
  end

  @required_fields ~w(conversation_id summary)a
  @optional_fields ~w(key_topics message_count)a

  @doc """
  Changeset for creating or updating a conversation summary.
  """
  def changeset(summary, attrs) do
    summary
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:conversation_id, min: 1, max: 255)
    |> validate_length(:summary, min: 1, max: 10_000)
    |> validate_number(:message_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:conversation_id)
  end
end

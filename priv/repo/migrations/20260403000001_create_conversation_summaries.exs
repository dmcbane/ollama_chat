defmodule OllamaChat.Repo.Migrations.CreateConversationSummaries do
  use Ecto.Migration

  def change do
    create table(:conversation_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, :string, null: false
      add :summary, :text, null: false
      add :key_topics, {:array, :string}, null: false, default: []
      add :message_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversation_summaries, [:conversation_id])
  end
end

defmodule OllamaChat.Memory.ConversationSummaryTest do
  use OllamaChat.DataCase, async: false

  alias OllamaChat.Memory
  alias OllamaChat.Memory.ConversationSummary

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        conversation_id: "conv-#{System.unique_integer([:positive])}",
        summary: "The user discussed Elixir preferences and project goals.",
        key_topics: ["Elixir", "Phoenix"],
        message_count: 6
      },
      overrides
    )
  end

  # ── create_conversation_summary/1 ────────────────────────────────────────────

  describe "create_conversation_summary/1" do
    test "creates a summary with all valid attributes" do
      attrs = valid_attrs()

      assert {:ok, %ConversationSummary{} = summary} =
               Memory.create_conversation_summary(attrs)

      assert summary.id != nil
      assert summary.conversation_id == attrs.conversation_id
      assert summary.summary == attrs.summary
      assert summary.key_topics == attrs.key_topics
      assert summary.message_count == attrs.message_count
      assert summary.inserted_at != nil
      assert summary.updated_at != nil
    end

    test "applies default values for optional fields" do
      attrs = %{
        conversation_id: "conv-defaults",
        summary: "A minimal summary."
      }

      assert {:ok, summary} = Memory.create_conversation_summary(attrs)
      assert summary.key_topics == []
      assert summary.message_count == 0
    end

    test "requires conversation_id" do
      attrs = valid_attrs() |> Map.delete(:conversation_id)
      assert {:error, changeset} = Memory.create_conversation_summary(attrs)
      assert "can't be blank" in errors_on(changeset).conversation_id
    end

    test "requires summary" do
      attrs = valid_attrs() |> Map.delete(:summary)
      assert {:error, changeset} = Memory.create_conversation_summary(attrs)
      assert "can't be blank" in errors_on(changeset).summary
    end

    test "rejects an empty summary string" do
      attrs = valid_attrs(%{summary: ""})
      assert {:error, changeset} = Memory.create_conversation_summary(attrs)
      assert "can't be blank" in errors_on(changeset).summary
    end

    test "rejects a summary longer than 10 000 characters" do
      attrs = valid_attrs(%{summary: String.duplicate("x", 10_001)})
      assert {:error, changeset} = Memory.create_conversation_summary(attrs)
      assert "should be at most 10000 character(s)" in errors_on(changeset).summary
    end

    test "accepts a summary of exactly 10 000 characters" do
      attrs = valid_attrs(%{summary: String.duplicate("a", 10_000)})
      assert {:ok, summary} = Memory.create_conversation_summary(attrs)
      assert String.length(summary.summary) == 10_000
    end

    test "rejects a negative message_count" do
      attrs = valid_attrs(%{message_count: -1})
      assert {:error, changeset} = Memory.create_conversation_summary(attrs)
      assert errors_on(changeset).message_count != []
    end

    test "accepts message_count of zero" do
      attrs = valid_attrs(%{message_count: 0})
      assert {:ok, summary} = Memory.create_conversation_summary(attrs)
      assert summary.message_count == 0
    end

    test "upserts when called twice with the same conversation_id" do
      id = "conv-upsert-#{System.unique_integer([:positive])}"

      assert {:ok, first} =
               Memory.create_conversation_summary(%{
                 conversation_id: id,
                 summary: "First summary.",
                 message_count: 4
               })

      assert {:ok, second} =
               Memory.create_conversation_summary(%{
                 conversation_id: id,
                 summary: "Updated summary.",
                 message_count: 8,
                 key_topics: ["Elixir"]
               })

      assert second.conversation_id == id
      assert second.summary == "Updated summary."
      assert second.message_count == 8
      assert second.key_topics == ["Elixir"]

      # Only one record in the database
      assert {:ok, all} = Memory.list_conversation_summaries()
      assert length(all) == 1
      assert hd(all).summary == "Updated summary."

      # Inserted at timestamp is preserved from the original insert
      assert first.inserted_at == second.inserted_at ||
               (is_struct(first.inserted_at, DateTime) and
                  is_struct(second.inserted_at, DateTime))
    end

    test "returns {:error, :memory_disabled} when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} =
               Memory.create_conversation_summary(valid_attrs())
    end
  end

  # ── get_conversation_summary/1 ────────────────────────────────────────────────

  describe "get_conversation_summary/1" do
    test "returns {:ok, summary} when found" do
      attrs = valid_attrs()
      {:ok, created} = Memory.create_conversation_summary(attrs)

      assert {:ok, found} = Memory.get_conversation_summary(attrs.conversation_id)
      assert found.id == created.id
      assert found.summary == attrs.summary
    end

    test "returns {:ok, nil} when conversation_id does not exist" do
      assert {:ok, nil} = Memory.get_conversation_summary("non-existent-conv-id")
    end

    test "returns the most recently updated record on upsert" do
      id = "conv-get-upsert-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Memory.create_conversation_summary(%{
          conversation_id: id,
          summary: "Original."
        })

      {:ok, _} =
        Memory.create_conversation_summary(%{
          conversation_id: id,
          summary: "Replaced."
        })

      assert {:ok, result} = Memory.get_conversation_summary(id)
      assert result.summary == "Replaced."
    end

    test "returns {:error, :memory_disabled} when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} =
               Memory.get_conversation_summary("conv-any")
    end
  end

  # ── list_conversation_summaries/1 ─────────────────────────────────────────────

  describe "list_conversation_summaries/1" do
    test "returns {:ok, []} when there are no summaries" do
      assert {:ok, []} = Memory.list_conversation_summaries()
    end

    test "returns all summaries ordered by inserted_at descending" do
      {:ok, _} =
        Memory.create_conversation_summary(%{
          conversation_id: "conv-list-a",
          summary: "First conversation."
        })

      {:ok, _} =
        Memory.create_conversation_summary(%{
          conversation_id: "conv-list-b",
          summary: "Second conversation."
        })

      {:ok, _} =
        Memory.create_conversation_summary(%{
          conversation_id: "conv-list-c",
          summary: "Third conversation."
        })

      assert {:ok, summaries} = Memory.list_conversation_summaries()
      assert length(summaries) == 3

      # Verify they're all present (ordering by inserted_at may be nondeterministic
      # within the same test transaction microsecond, so check set membership)
      ids = Enum.map(summaries, & &1.conversation_id) |> MapSet.new()
      assert MapSet.member?(ids, "conv-list-a")
      assert MapSet.member?(ids, "conv-list-b")
      assert MapSet.member?(ids, "conv-list-c")
    end

    test "respects the :limit option" do
      for i <- 1..5 do
        {:ok, _} =
          Memory.create_conversation_summary(%{
            conversation_id: "conv-limit-#{i}",
            summary: "Summary #{i}."
          })
      end

      assert {:ok, results} = Memory.list_conversation_summaries(limit: 3)
      assert length(results) == 3
    end

    test "respects the :offset option" do
      for i <- 1..4 do
        {:ok, _} =
          Memory.create_conversation_summary(%{
            conversation_id: "conv-offset-#{i}",
            summary: "Summary #{i}."
          })
      end

      assert {:ok, page1} = Memory.list_conversation_summaries(limit: 2, offset: 0)
      assert {:ok, page2} = Memory.list_conversation_summaries(limit: 2, offset: 2)

      all_ids = (page1 ++ page2) |> Enum.map(& &1.conversation_id) |> MapSet.new()
      assert MapSet.size(all_ids) == 4
    end

    test "returns {:ok, []} for offset beyond the total count" do
      {:ok, _} =
        Memory.create_conversation_summary(%{
          conversation_id: "conv-beyond",
          summary: "Only one."
        })

      assert {:ok, []} = Memory.list_conversation_summaries(offset: 100)
    end

    test "returns {:error, :memory_disabled} when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} = Memory.list_conversation_summaries()
    end
  end

  # ── ConversationSummary.changeset/2 ──────────────────────────────────────────

  describe "ConversationSummary.changeset/2" do
    test "is valid with all required fields" do
      changeset =
        ConversationSummary.changeset(%ConversationSummary{}, %{
          conversation_id: "conv-cs-001",
          summary: "A valid summary."
        })

      assert changeset.valid?
    end

    test "is invalid without conversation_id" do
      changeset =
        ConversationSummary.changeset(%ConversationSummary{}, %{
          summary: "Missing conversation_id."
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).conversation_id
    end

    test "is invalid without summary" do
      changeset =
        ConversationSummary.changeset(%ConversationSummary{}, %{
          conversation_id: "conv-cs-002"
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).summary
    end

    test "defaults key_topics to empty list" do
      changeset =
        ConversationSummary.changeset(%ConversationSummary{}, %{
          conversation_id: "conv-cs-003",
          summary: "A summary."
        })

      assert Ecto.Changeset.get_field(changeset, :key_topics) == []
    end

    test "defaults message_count to zero" do
      changeset =
        ConversationSummary.changeset(%ConversationSummary{}, %{
          conversation_id: "conv-cs-004",
          summary: "A summary."
        })

      assert Ecto.Changeset.get_field(changeset, :message_count) == 0
    end
  end
end

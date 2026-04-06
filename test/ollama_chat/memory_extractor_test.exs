defmodule OllamaChat.Memory.ExtractorTest do
  use OllamaChat.DataCase, async: true

  alias OllamaChat.Embeddings
  alias OllamaChat.Memory
  alias OllamaChat.Memory.ConversationSummary
  alias OllamaChat.Memory.Extractor

  # 768-dimension fake embeddings (match nomic-embed-text dimensionality)
  @fake_embedding Enum.map(1..768, fn i -> :math.sin(i / 100) end)
  @fake_embedding_2 Enum.map(1..768, fn i -> :math.cos(i / 100) end)

  # A conversation long enough to trigger extraction (>= 5 messages)
  defp sample_messages do
    [
      %{role: "user", content: "My name is Alice and I love Elixir"},
      %{role: "assistant", content: "Nice to meet you, Alice! Elixir is a great language."},
      %{role: "user", content: "I prefer dark mode and concise answers"},
      %{role: "assistant", content: "Noted! I'll keep that in mind."},
      %{role: "user", content: "I'm working on an Ollama chat project"}
    ]
  end

  # A conversation too short to trigger extraction
  defp short_messages do
    [
      %{role: "user", content: "Hello"},
      %{role: "assistant", content: "Hi!"}
    ]
  end

  # Builds a mock chat_fn that returns the given JSON string as LLM content
  defp mock_chat_fn(json) do
    fn _messages, _opts ->
      {:ok, %{"message" => %{"content" => json}}}
    end
  end

  # Builds a mock embedding_fn that always returns a fixed embedding vector
  defp mock_embed_ok(embedding \\ @fake_embedding) do
    fn _text -> {:ok, embedding} end
  end

  defp mock_embed_fail do
    fn _text -> {:error, :embedding_unavailable} end
  end

  # Returns an embedding_fn that cycles through the given list of embeddings in
  # order, one per call. Useful for tests that save multiple memories and need
  # distinct embeddings per item so dedup doesn't incorrectly collapse them.
  defp make_embedding_sequence(embeddings) do
    counter = :counters.new(1, [])

    fn _text ->
      idx = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      {:ok, Enum.at(embeddings, rem(idx, length(embeddings)))}
    end
  end

  # Creates a memory entry with an embedding stored synchronously (in test process)
  defp create_memory_with_vec!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{content: "Existing memory", memory_type: "fact", source: "llm_explicit"},
        overrides
      )

    entry = Memory.create_memory!(attrs)
    {:ok, _} = Embeddings.store_embedding(entry, @fake_embedding)
    entry
  end

  # ── should_extract?/1 ────────────────────────────────────────────────────────

  describe "should_extract?/1" do
    test "returns true when messages count meets the default threshold" do
      assert Extractor.should_extract?(sample_messages()) == true
    end

    test "returns false when messages count is below threshold" do
      assert Extractor.should_extract?(short_messages()) == false
    end

    test "returns false for an empty list" do
      assert Extractor.should_extract?([]) == false
    end

    test "returns true at exactly the threshold (5 messages)" do
      messages = Enum.map(1..5, fn i -> %{role: "user", content: "message #{i}"} end)
      assert Extractor.should_extract?(messages) == true
    end

    test "returns false for 4 messages (one below default threshold)" do
      messages = Enum.map(1..4, fn i -> %{role: "user", content: "message #{i}"} end)
      assert Extractor.should_extract?(messages) == false
    end

    test "respects :memory_extraction_min_messages app config" do
      Application.put_env(:ollama_chat, :memory_extraction_min_messages, 2)
      on_exit(fn -> Application.delete_env(:ollama_chat, :memory_extraction_min_messages) end)

      assert Extractor.should_extract?(short_messages()) == true
    end
  end

  # ── deduplicate/2 ────────────────────────────────────────────────────────────

  describe "deduplicate/2" do
    test "returns :new when no memories exist in the database" do
      result = Extractor.deduplicate("User prefers Elixir", embedding_fn: mock_embed_ok())
      assert result == :new
    end

    test "returns :new when existing memories have dissimilar embeddings" do
      # Store a memory with @fake_embedding_2 (different from query embedding)
      entry =
        Memory.create_memory!(%{
          content: "Other fact",
          memory_type: "fact",
          source: "llm_explicit"
        })

      {:ok, _} = Embeddings.store_embedding(entry, @fake_embedding_2)

      # Query with @fake_embedding (dissimilar) — distance will be large, above threshold
      result = Extractor.deduplicate("New content", embedding_fn: mock_embed_ok(@fake_embedding))
      assert result == :new
    end

    test "returns {:duplicate, entry} when an identical-embedding memory exists" do
      existing = create_memory_with_vec!(%{content: "User prefers Elixir"})

      # Query embedding matches the stored one exactly → distance = 0.0 < threshold
      result =
        Extractor.deduplicate("User prefers Elixir",
          embedding_fn: mock_embed_ok(@fake_embedding),
          threshold: 0.5
        )

      assert {:duplicate, found} = result
      assert found.id == existing.id
    end

    test "returns :new when embedding generation fails" do
      _existing = create_memory_with_vec!()

      result = Extractor.deduplicate("Some text", embedding_fn: mock_embed_fail())
      assert result == :new
    end

    test "respects a custom :threshold option (tight threshold rejects near-duplicates)" do
      # Store a memory with @fake_embedding
      _existing = create_memory_with_vec!()

      # With threshold 0.0, nothing can ever match (distance is never truly < 0.0)
      result =
        Extractor.deduplicate("Some text",
          embedding_fn: mock_embed_ok(@fake_embedding),
          threshold: 0.0
        )

      assert result == :new
    end

    test "returns :new when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      # search_by_similarity_with_scores returns {:error, :memory_disabled} →
      # find_duplicate degrades to :new
      result = Extractor.deduplicate("Some text", embedding_fn: mock_embed_ok())
      assert result == :new
    end
  end

  # ── extract_from_conversation/3 ──────────────────────────────────────────────

  describe "extract_from_conversation/3" do
    test "extracts and saves memories from a conversation" do
      json =
        Jason.encode!([
          %{content: "User's name is Alice", memory_type: "fact", importance: 0.9},
          %{content: "User prefers dark mode", memory_type: "preference", importance: 0.7}
        ])

      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-001",
                 sample_messages(),
                 chat_fn: mock_chat_fn(json),
                 embedding_fn: make_embedding_sequence([@fake_embedding, @fake_embedding_2])
               )

      assert result.memories_saved == 2
      assert result.memories_skipped == 0

      assert {:ok, memories} = Memory.list_memories(source: "auto_extract")
      assert length(memories) == 2
    end

    test "assigns correct fields to saved memories" do
      json =
        Jason.encode!([
          %{content: "User works on Elixir projects", memory_type: "context", importance: 0.8}
        ])

      assert {:ok, _} =
               Extractor.extract_from_conversation(
                 "conv-fields",
                 sample_messages(),
                 chat_fn: mock_chat_fn(json),
                 embedding_fn: mock_embed_ok()
               )

      assert {:ok, [memory]} = Memory.list_memories(source: "auto_extract")
      assert memory.content == "User works on Elixir projects"
      assert memory.memory_type == "context"
      assert memory.importance == 0.8
      assert memory.source == "auto_extract"
      assert memory.conversation_id == "conv-fields"
    end

    test "skips duplicate memories that already exist in the database" do
      existing = create_memory_with_vec!(%{content: "User's name is Alice"})

      json =
        Jason.encode!([
          %{content: "User's name is Alice", memory_type: "fact", importance: 0.8},
          %{content: "User prefers dark mode", memory_type: "preference", importance: 0.6}
        ])

      # @fake_embedding matches existing → first item is a duplicate
      # @fake_embedding_2 is different → second item is new
      call_count = :counters.new(1, [])

      embedding_fn = fn _text ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0,
          do: {:ok, @fake_embedding},
          else: {:ok, @fake_embedding_2}
      end

      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-dup",
                 sample_messages(),
                 chat_fn: mock_chat_fn(json),
                 embedding_fn: embedding_fn,
                 dedup_threshold: 0.5
               )

      assert result.memories_saved == 1
      assert result.memories_skipped == 1

      # Only the non-duplicate memory is saved
      assert {:ok, saved} = Memory.list_memories(source: "auto_extract")
      assert length(saved) == 1
      assert hd(saved).content == "User prefers dark mode"

      # The existing memory is untouched
      assert {:ok, existing_check} = Memory.get_memory(existing.id)
      assert existing_check.source == "llm_explicit"
    end

    test "skips items with empty content" do
      json =
        Jason.encode!([
          %{content: "", memory_type: "fact", importance: 0.8},
          %{content: "   ", memory_type: "fact", importance: 0.8},
          %{content: "User likes Elixir", memory_type: "fact", importance: 0.7}
        ])

      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-empty",
                 sample_messages(),
                 chat_fn: mock_chat_fn(json),
                 embedding_fn: mock_embed_ok()
               )

      assert result.memories_saved == 1
      assert result.memories_skipped == 2
    end

    test "handles malformed JSON gracefully — returns ok with zero saved" do
      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-bad-json",
                 sample_messages(),
                 chat_fn: mock_chat_fn("not valid json at all"),
                 embedding_fn: mock_embed_ok()
               )

      assert result.memories_saved == 0
      assert result.memories_skipped == 0
    end

    test "handles the LLM returning an empty JSON array" do
      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-empty-arr",
                 sample_messages(),
                 chat_fn: mock_chat_fn("[]"),
                 embedding_fn: mock_embed_ok()
               )

      assert result.memories_saved == 0
      assert result.memories_skipped == 0
    end

    test "returns {:error, {:chat_failed, _}} when the LLM call fails" do
      failing_chat = fn _msgs, _opts -> {:error, "connection refused"} end

      assert {:error, {:chat_failed, _reason}} =
               Extractor.extract_from_conversation(
                 "conv-fail",
                 sample_messages(),
                 chat_fn: failing_chat
               )
    end

    test "returns {:error, :memory_disabled} when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} =
               Extractor.extract_from_conversation(
                 "conv-disabled",
                 sample_messages(),
                 chat_fn: mock_chat_fn("[]")
               )
    end

    test "clamps importance values outside 0.0–1.0" do
      json =
        Jason.encode!([
          %{content: "User likes cats", memory_type: "fact", importance: 2.5},
          %{content: "User likes dogs", memory_type: "fact", importance: -0.3}
        ])

      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-clamp",
                 sample_messages(),
                 chat_fn: mock_chat_fn(json),
                 embedding_fn: make_embedding_sequence([@fake_embedding, @fake_embedding_2])
               )

      assert result.memories_saved == 2
      assert {:ok, memories} = Memory.list_memories(source: "auto_extract")
      importances = Enum.map(memories, & &1.importance) |> Enum.sort()
      assert Enum.all?(importances, fn i -> i >= 0.0 and i <= 1.0 end)
    end

    test "normalises unknown memory_type values to \"fact\"" do
      json =
        Jason.encode!([
          %{content: "User prefers Vim", memory_type: "unknown_type", importance: 0.6}
        ])

      assert {:ok, _} =
               Extractor.extract_from_conversation(
                 "conv-type",
                 sample_messages(),
                 chat_fn: mock_chat_fn(json),
                 embedding_fn: mock_embed_ok(@fake_embedding_2)
               )

      assert {:ok, [memory]} = Memory.list_memories(source: "auto_extract")
      assert memory.memory_type == "fact"
    end

    test "strips markdown code fences from LLM response" do
      fenced =
        """
        ```json
        [{"content": "User uses NeoVim", "memory_type": "preference", "importance": 0.6}]
        ```
        """

      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-fenced",
                 sample_messages(),
                 chat_fn: mock_chat_fn(fenced),
                 embedding_fn: mock_embed_ok(@fake_embedding_2)
               )

      assert result.memories_saved == 1
    end

    test "handles string-keyed messages (loaded from localStorage JSON)" do
      string_keyed_messages = [
        %{"role" => "user", "content" => "I use Vim"},
        %{"role" => "assistant", "content" => "Noted"},
        %{"role" => "user", "content" => "I prefer Elixir"},
        %{"role" => "assistant", "content" => "Great choice"},
        %{"role" => "user", "content" => "Working on a Phoenix app"}
      ]

      json =
        Jason.encode!([
          %{content: "User prefers Vim", memory_type: "preference", importance: 0.6}
        ])

      assert {:ok, result} =
               Extractor.extract_from_conversation(
                 "conv-string-keys",
                 string_keyed_messages,
                 chat_fn: mock_chat_fn(json),
                 embedding_fn: mock_embed_ok(@fake_embedding_2)
               )

      assert result.memories_saved == 1
    end
  end

  # ── summarize/3 ──────────────────────────────────────────────────────────────

  describe "summarize/3" do
    test "creates and stores a conversation summary" do
      summary_text =
        "The user introduced themselves as Alice and stated preferences for dark mode."

      assert {:ok, %ConversationSummary{} = summary} =
               Extractor.summarize(
                 "conv-sum-001",
                 sample_messages(),
                 chat_fn: mock_chat_fn(summary_text)
               )

      assert summary.conversation_id == "conv-sum-001"
      assert summary.summary == summary_text
      assert summary.message_count == length(sample_messages())
      assert summary.key_topics == []
    end

    test "summary is retrievable via Memory.get_conversation_summary/1" do
      summary_text = "User discussed Elixir preferences."

      assert {:ok, _} =
               Extractor.summarize(
                 "conv-sum-retrieve",
                 sample_messages(),
                 chat_fn: mock_chat_fn(summary_text)
               )

      assert {:ok, stored} = Memory.get_conversation_summary("conv-sum-retrieve")
      assert stored.summary == summary_text
    end

    test "upserts when called twice for the same conversation_id" do
      assert {:ok, _} =
               Extractor.summarize(
                 "conv-sum-upsert",
                 sample_messages(),
                 chat_fn: mock_chat_fn("First summary.")
               )

      assert {:ok, _} =
               Extractor.summarize(
                 "conv-sum-upsert",
                 sample_messages(),
                 chat_fn: mock_chat_fn("Updated summary.")
               )

      assert {:ok, updated} = Memory.get_conversation_summary("conv-sum-upsert")
      assert updated.summary == "Updated summary."

      # Only one record exists
      assert {:ok, all} = Memory.list_conversation_summaries()
      assert length(all) == 1
    end

    test "returns {:error, {:chat_failed, _}} when the LLM call fails" do
      failing_chat = fn _msgs, _opts -> {:error, "timeout"} end

      assert {:error, {:chat_failed, _reason}} =
               Extractor.summarize("conv-sum-fail", sample_messages(), chat_fn: failing_chat)
    end

    test "returns {:error, :memory_disabled} when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} =
               Extractor.summarize(
                 "conv-sum-disabled",
                 sample_messages(),
                 chat_fn: mock_chat_fn("Summary text.")
               )
    end

    test "trims whitespace from the LLM response before storing" do
      padded = "  \n  Summary with surrounding whitespace.  \n  "

      assert {:ok, summary} =
               Extractor.summarize(
                 "conv-sum-trim",
                 sample_messages(),
                 chat_fn: mock_chat_fn(padded)
               )

      assert summary.summary == "Summary with surrounding whitespace."
    end

    test "stores the correct message count" do
      assert {:ok, summary} =
               Extractor.summarize(
                 "conv-sum-count",
                 sample_messages(),
                 chat_fn: mock_chat_fn("A summary.")
               )

      assert summary.message_count == 5
    end
  end

  # ── extract_and_save_async/3 ─────────────────────────────────────────────────

  describe "extract_and_save_async/3" do
    test "returns :ok immediately without blocking" do
      result =
        Extractor.extract_and_save_async(
          "conv-async-001",
          sample_messages(),
          chat_fn: mock_chat_fn("[]"),
          embedding_fn: mock_embed_ok()
        )

      assert result == :ok
    end

    test "accepts atom-keyed message maps" do
      result =
        Extractor.extract_and_save_async(
          "conv-async-atom",
          sample_messages(),
          chat_fn: mock_chat_fn("[]"),
          embedding_fn: mock_embed_ok()
        )

      assert result == :ok
    end
  end
end

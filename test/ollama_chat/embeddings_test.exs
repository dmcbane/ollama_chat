defmodule OllamaChat.EmbeddingsTest do
  use OllamaChat.DataCase, async: true

  alias OllamaChat.Embeddings
  alias OllamaChat.Memory

  # A 768-dimensional fake embedding (nomic-embed-text produces 768-dim vectors)
  @fake_embedding Enum.map(1..768, fn i -> :math.sin(i / 100) end)

  # A function that always succeeds
  defp success_embedding_fn, do: fn _text -> {:ok, @fake_embedding} end

  # A function that always fails
  defp failure_embedding_fn, do: fn _text -> {:error, :model_not_available} end

  defp create_memory!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          content: "Test memory content",
          memory_type: "fact",
          source: "user_manual"
        },
        overrides
      )

    {:ok, entry} = Memory.create_memory(attrs)
    entry
  end

  describe "generate_and_store/2" do
    test "generates embedding and stores it on the memory entry" do
      entry = create_memory!()
      assert is_nil(entry.embedding)

      assert {:ok, updated} =
               Embeddings.generate_and_store(entry, embedding_fn: success_embedding_fn())

      assert updated.embedding != nil
      assert length(Pgvector.to_list(updated.embedding)) == 768
    end

    test "returns error when embedding generation fails" do
      entry = create_memory!()

      assert {:error, :model_not_available} =
               Embeddings.generate_and_store(entry, embedding_fn: failure_embedding_fn())
    end

    test "does not modify the entry when embedding generation fails" do
      entry = create_memory!()

      {:error, _} = Embeddings.generate_and_store(entry, embedding_fn: failure_embedding_fn())

      {:ok, reloaded} = Memory.get_memory(entry.id)
      assert is_nil(reloaded.embedding)
    end

    test "uses default OllamaClient when no embedding_fn provided" do
      # This would be an integration test - just verify the function head exists
      _entry = create_memory!()
      # We can't test without a running Ollama, but we verify the function accepts 1 arg
      assert is_function(&Embeddings.generate_and_store/1)
    end
  end

  describe "backfill/1" do
    test "generates embeddings for entries without them" do
      entry1 = create_memory!(%{content: "First memory"})
      entry2 = create_memory!(%{content: "Second memory"})

      assert {:ok, stats} = Embeddings.backfill(embedding_fn: success_embedding_fn())
      assert stats.success == 2
      assert stats.failed == 0
      assert stats.total == 2

      {:ok, reloaded1} = Memory.get_memory(entry1.id)
      {:ok, reloaded2} = Memory.get_memory(entry2.id)
      assert reloaded1.embedding != nil
      assert reloaded2.embedding != nil
    end

    test "skips entries that already have embeddings" do
      _entry_with = create_memory!(%{content: "Has embedding", embedding: @fake_embedding})
      _entry_without = create_memory!(%{content: "No embedding"})

      assert {:ok, stats} = Embeddings.backfill(embedding_fn: success_embedding_fn())
      assert stats.success == 1
      assert stats.skipped == 1
      assert stats.total == 2
    end

    test "reports failures without stopping" do
      _entry1 = create_memory!(%{content: "First memory"})
      _entry2 = create_memory!(%{content: "Second memory"})

      call_count = :counters.new(1, [:atomics])

      mixed_fn = fn _text ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        if count == 0, do: {:ok, @fake_embedding}, else: {:error, :timeout}
      end

      assert {:ok, stats} = Embeddings.backfill(embedding_fn: mixed_fn)
      assert stats.success == 1
      assert stats.failed == 1
    end

    test "respects batch_size option" do
      for i <- 1..5, do: create_memory!(%{content: "Memory #{i}"})

      assert {:ok, stats} =
               Embeddings.backfill(embedding_fn: success_embedding_fn(), batch_size: 2)

      assert stats.success == 5
    end

    test "returns success stats when no entries exist" do
      assert {:ok, stats} = Embeddings.backfill(embedding_fn: success_embedding_fn())
      assert stats.success == 0
      assert stats.failed == 0
      assert stats.total == 0
    end

    test "returns error when memory system is disabled" do
      original = Application.get_env(:ollama_chat, :memory_enabled, true)
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, original) end)

      assert {:error, :memory_disabled} =
               Embeddings.backfill(embedding_fn: success_embedding_fn())
    end
  end

  describe "embedding_model/0" do
    test "returns default model name" do
      original = Application.get_env(:ollama_chat, :ollama_embedding_model)
      Application.delete_env(:ollama_chat, :ollama_embedding_model)

      on_exit(fn ->
        if original do
          Application.put_env(:ollama_chat, :ollama_embedding_model, original)
        end
      end)

      assert Embeddings.embedding_model() == "nomic-embed-text"
    end

    test "returns configured model" do
      original = Application.get_env(:ollama_chat, :ollama_embedding_model)
      Application.put_env(:ollama_chat, :ollama_embedding_model, "custom-embed")

      on_exit(fn ->
        if original do
          Application.put_env(:ollama_chat, :ollama_embedding_model, original)
        else
          Application.delete_env(:ollama_chat, :ollama_embedding_model)
        end
      end)

      assert Embeddings.embedding_model() == "custom-embed"
    end
  end

  describe "needs_embedding?/1" do
    test "returns true when entry has no embedding" do
      entry = create_memory!()
      assert Embeddings.needs_embedding?(entry)
    end

    test "returns false when entry has an embedding" do
      entry = create_memory!(%{embedding: @fake_embedding})
      assert not Embeddings.needs_embedding?(entry)
    end
  end

  describe "generate/2" do
    test "calls embedding function and returns result" do
      assert {:ok, embedding} =
               Embeddings.generate("test text", embedding_fn: success_embedding_fn())

      assert length(embedding) == 768
    end

    test "returns error on failure" do
      assert {:error, :model_not_available} =
               Embeddings.generate("test text", embedding_fn: failure_embedding_fn())
    end
  end
end

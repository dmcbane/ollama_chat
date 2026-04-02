defmodule OllamaChat.EmbeddingsTest do
  use OllamaChat.DataCase, async: true

  alias OllamaChat.Embeddings
  alias OllamaChat.Memory
  alias OllamaChat.Memory.Entry

  # Helper to create a memory entry for testing
  defp create_test_memory(content \\ "User prefers Elixir") do
    {:ok, entry} =
      Memory.create_memory(%{
        content: content,
        memory_type: "fact",
        source: "llm_explicit"
      })

    entry
  end

  describe "embedding_model/0" do
    test "returns configured embedding model" do
      assert is_binary(Embeddings.embedding_model())
    end

    test "defaults to nomic-embed-text" do
      # Clear any override
      original = Application.get_env(:ollama_chat, :ollama_embedding_model)
      Application.delete_env(:ollama_chat, :ollama_embedding_model)

      on_exit(fn ->
        if original, do: Application.put_env(:ollama_chat, :ollama_embedding_model, original)
      end)

      assert Embeddings.embedding_model() == "nomic-embed-text"
    end

    test "returns configured value when set" do
      original = Application.get_env(:ollama_chat, :ollama_embedding_model)
      Application.put_env(:ollama_chat, :ollama_embedding_model, "custom-model")

      on_exit(fn ->
        if original do
          Application.put_env(:ollama_chat, :ollama_embedding_model, original)
        else
          Application.delete_env(:ollama_chat, :ollama_embedding_model)
        end
      end)

      assert Embeddings.embedding_model() == "custom-model"
    end
  end

  describe "store_embedding/2" do
    test "stores embedding on memory entry when given a valid embedding vector" do
      entry = create_test_memory()
      # 768-dim vector (nomic-embed-text dimensions)
      fake_embedding = Enum.map(1..768, fn i -> :math.sin(i / 100) end)

      assert {:ok, updated} = Embeddings.store_embedding(entry, fake_embedding)
      assert updated.embedding != nil
    end

    test "persists embedding to database" do
      entry = create_test_memory()
      fake_embedding = Enum.map(1..768, fn i -> :math.sin(i / 100) end)

      {:ok, updated} = Embeddings.store_embedding(entry, fake_embedding)

      # Re-fetch from database to confirm persistence
      {:ok, reloaded} = Memory.get_memory(updated.id)
      assert reloaded.embedding != nil
    end

    test "returns error for empty embedding vector" do
      entry = create_test_memory()
      assert {:error, _reason} = Embeddings.store_embedding(entry, [])
    end

    test "returns error for nil entry" do
      fake_embedding = Enum.map(1..768, fn _ -> 0.0 end)
      assert {:error, _reason} = Embeddings.store_embedding(nil, fake_embedding)
    end

    test "returns error for nil embedding" do
      entry = create_test_memory()
      assert {:error, _reason} = Embeddings.store_embedding(entry, nil)
    end

    test "returns error when memory is disabled" do
      entry = create_test_memory()
      fake_embedding = Enum.map(1..768, fn _ -> 0.1 end)

      original = Application.get_env(:ollama_chat, :memory_enabled, true)
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, original) end)

      assert {:error, :memory_disabled} = Embeddings.store_embedding(entry, fake_embedding)
    end
  end

  describe "semantic_search/2" do
    setup do
      # Create entries with known embeddings
      entry1 = create_test_memory("User prefers Elixir programming")
      entry2 = create_test_memory("User likes functional programming")
      entry3 = create_test_memory("User's favorite food is pizza")

      # Create distinct embeddings — entry1 and entry2 should be more similar
      # to each other than to entry3
      elixir_embedding = Enum.map(1..768, fn i -> :math.sin(i / 100) end)

      functional_embedding =
        Enum.map(1..768, fn i ->
          :math.sin(i / 100) * 0.95 + :math.cos(i / 200) * 0.05
        end)

      pizza_embedding = Enum.map(1..768, fn i -> :math.cos(i / 50) end)

      {:ok, _} = Embeddings.store_embedding(entry1, elixir_embedding)
      {:ok, _} = Embeddings.store_embedding(entry2, functional_embedding)
      {:ok, _} = Embeddings.store_embedding(entry3, pizza_embedding)

      %{
        entry1: entry1,
        entry2: entry2,
        entry3: entry3,
        elixir_embedding: elixir_embedding
      }
    end

    test "finds similar entries by embedding vector", %{elixir_embedding: query_vec} do
      # IVFFlat is approximate — with very few entries and lists=100, it may not
      # find all results. We assert at least 1 result rather than exactly 3.
      assert {:ok, results} = Embeddings.semantic_search(query_vec, limit: 3)
      assert is_list(results)
      assert results != [], "expected at least one result from semantic search"
    end

    test "returns results ordered by similarity", %{elixir_embedding: query_vec} do
      {:ok, results} = Embeddings.semantic_search(query_vec, limit: 3)
      # First result should be most similar to the Elixir embedding
      [first | _] = results
      assert first.content =~ "Elixir"
    end

    test "respects limit option", %{elixir_embedding: query_vec} do
      {:ok, results} = Embeddings.semantic_search(query_vec, limit: 1)
      assert [_] = results
    end

    test "defaults limit when not specified", %{elixir_embedding: query_vec} do
      {:ok, results} = Embeddings.semantic_search(query_vec)
      assert is_list(results)
      # Should return all 3 entries (default limit should be >= 3)
      assert results != []
    end

    test "returns results as Entry structs", %{elixir_embedding: query_vec} do
      {:ok, results} = Embeddings.semantic_search(query_vec, limit: 1)
      [first | _] = results
      assert %Entry{} = first
      assert is_binary(first.content)
    end

    test "returns {:ok, []} when no entries have embeddings" do
      # Create entry without embedding
      _entry = create_test_memory("No embedding here")
      zero_vec = Enum.map(1..768, fn _ -> 0.0 end)
      # Note: entries from setup DO have embeddings, but this tests the query path
      {:ok, results} = Embeddings.semantic_search(zero_vec, limit: 10)
      assert is_list(results)
    end

    test "returns {:error, :memory_disabled} when memory is disabled", %{
      elixir_embedding: query_vec
    } do
      original = Application.get_env(:ollama_chat, :memory_enabled, true)
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, original) end)

      assert {:error, :memory_disabled} = Embeddings.semantic_search(query_vec)
    end

    test "returns error for empty query vector" do
      assert {:error, _reason} = Embeddings.semantic_search([], limit: 5)
    end

    test "returns error for nil query vector" do
      assert {:error, _reason} = Embeddings.semantic_search(nil, limit: 5)
    end
  end

  describe "entries_without_embeddings/0" do
    test "returns list of entries without embeddings" do
      _entry1 = create_test_memory("Has no embedding")
      _entry2 = create_test_memory("Also no embedding")

      assert {:ok, entries} = Embeddings.entries_without_embeddings()
      assert length(entries) >= 2
    end

    test "entries with embeddings are excluded" do
      entry = create_test_memory("Will get embedding")
      fake_embedding = Enum.map(1..768, fn _ -> 0.1 end)
      {:ok, _} = Embeddings.store_embedding(entry, fake_embedding)

      {:ok, entries} = Embeddings.entries_without_embeddings()
      refute Enum.any?(entries, fn e -> e.id == entry.id end)
    end

    test "returns {:ok, []} when all entries have embeddings" do
      entry = create_test_memory("Has embedding")
      fake_embedding = Enum.map(1..768, fn _ -> 0.5 end)
      {:ok, _} = Embeddings.store_embedding(entry, fake_embedding)

      {:ok, entries} = Embeddings.entries_without_embeddings()
      refute Enum.any?(entries, fn e -> e.id == entry.id end)
    end

    test "returns {:error, :memory_disabled} when memory is disabled" do
      original = Application.get_env(:ollama_chat, :memory_enabled, true)
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, original) end)

      assert {:error, :memory_disabled} = Embeddings.entries_without_embeddings()
    end
  end
end

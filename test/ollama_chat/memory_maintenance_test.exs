defmodule OllamaChat.MemoryMaintenanceTest do
  use OllamaChat.DataCase, async: false

  alias OllamaChat.Embeddings
  alias OllamaChat.Memory
  alias OllamaChat.Memory.Entry
  alias OllamaChat.Memory.Manager

  @fake_embedding Enum.map(1..768, fn i -> :math.sin(i / 100) end)
  @fake_embedding_2 Enum.map(1..768, fn i -> :math.cos(i / 100) end)

  defp create!(overrides \\ %{}) do
    Map.merge(%{content: "A fact", memory_type: "fact", source: "llm_explicit"}, overrides)
    |> Memory.create_memory!()
  end

  defp create_with_vec!(overrides \\ %{}) do
    entry = create!(overrides)
    {:ok, _} = Embeddings.store_embedding(entry, @fake_embedding)
    entry
  end

  # ── decay_importance/0 ───────────────────────────────────────────────────────

  describe "decay_importance/0" do
    test "decays importance for memories not accessed in 30+ days" do
      old_ts = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)
      entry = create!(%{importance: 0.8, last_accessed_at: old_ts})

      assert {:ok, 1} = Memory.decay_importance()

      assert {:ok, updated} = Memory.get_memory(entry.id)
      assert updated.importance < 0.8
      # 0.8 * 0.95 = 0.76
      assert_in_delta updated.importance, 0.76, 0.001
    end

    test "does not decay recently accessed memories" do
      recent = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      entry = create!(%{importance: 0.8, last_accessed_at: recent})

      assert {:ok, 0} = Memory.decay_importance()

      assert {:ok, unchanged} = Memory.get_memory(entry.id)
      assert_in_delta unchanged.importance, 0.8, 0.001
    end

    test "does not decay memories already at 0.1 (floor)" do
      old_ts = DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:second)
      entry = create!(%{importance: 0.1, last_accessed_at: old_ts})

      assert {:ok, 0} = Memory.decay_importance()

      assert {:ok, unchanged} = Memory.get_memory(entry.id)
      assert_in_delta unchanged.importance, 0.1, 0.001
    end

    test "treats nil last_accessed_at as stale" do
      entry = create!(%{importance: 0.6})
      assert entry.last_accessed_at == nil

      assert {:ok, 1} = Memory.decay_importance()

      assert {:ok, updated} = Memory.get_memory(entry.id)
      assert updated.importance < 0.6
    end

    test "floors decayed importance at 0.1" do
      old_ts = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)
      entry = create!(%{importance: 0.10001, last_accessed_at: old_ts})

      assert {:ok, 1} = Memory.decay_importance()

      assert {:ok, updated} = Memory.get_memory(entry.id)
      assert updated.importance >= 0.1
    end

    test "returns {:ok, 0} when no memories qualify" do
      # No memories in DB
      assert {:ok, 0} = Memory.decay_importance()
    end

    test "returns {:error, :memory_disabled} when disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} = Memory.decay_importance()
    end
  end

  # ── find_duplicates/1 ────────────────────────────────────────────────────────

  describe "find_duplicates/1" do
    test "returns empty list when no memories have embeddings" do
      _entry = create!()
      assert {:ok, []} = Memory.find_duplicates()
    end

    test "returns empty list when only one memory has an embedding" do
      _entry = create_with_vec!()
      assert {:ok, []} = Memory.find_duplicates()
    end

    test "returns pairs of nearly-identical embeddings" do
      e1 = create_with_vec!(%{content: "Fact A"})

      e2 =
        Memory.create_memory!(%{content: "Fact B", memory_type: "fact", source: "llm_explicit"})

      {:ok, _} = Embeddings.store_embedding(e2, @fake_embedding)

      assert {:ok, [{found1, found2, distance}]} = Memory.find_duplicates(0.5)
      ids = MapSet.new([found1.id, found2.id])
      assert MapSet.member?(ids, e1.id)
      assert MapSet.member?(ids, e2.id)
      assert distance >= 0.0
      assert distance < 0.5
    end

    test "does not return dissimilar pairs" do
      _e1 = create_with_vec!(%{content: "Fact A"})

      e2 =
        Memory.create_memory!(%{content: "Fact B", memory_type: "fact", source: "llm_explicit"})

      {:ok, _} = Embeddings.store_embedding(e2, @fake_embedding_2)

      # Distance between sin and cos embeddings is > 0.001 for sure
      assert {:ok, []} = Memory.find_duplicates(0.001)
    end

    test "returns {:error, :memory_disabled} when disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} = Memory.find_duplicates()
    end
  end

  # ── prune_to_limit/1 ─────────────────────────────────────────────────────────

  describe "prune_to_limit/1" do
    test "returns {:ok, 0} when count is at or below the limit" do
      create!(%{importance: 0.5})
      assert {:ok, 0} = Memory.prune_to_limit(10)
    end

    test "deletes lowest-scored memories when over the limit" do
      create!(%{content: "High importance", importance: 0.9})
      create!(%{content: "Low importance A", importance: 0.1})
      create!(%{content: "Low importance B", importance: 0.1})

      assert {:ok, 2} = Memory.prune_to_limit(1)

      assert {:ok, [remaining]} = Memory.list_memories()
      assert remaining.content == "High importance"
    end

    test "never prunes user_manual memories" do
      create!(%{content: "User saved", importance: 0.1, source: "user_manual"})
      create!(%{content: "Auto extracted", importance: 0.9, source: "auto_extract"})

      # Limit of 1 — only the auto_extract entry should be prunable,
      # but user_manual is protected. So prune count is 1 (auto_extract).
      assert {:ok, 1} = Memory.prune_to_limit(1)

      assert {:ok, [remaining]} = Memory.list_memories()
      assert remaining.source == "user_manual"
    end

    test "returns {:ok, 0} when all memories are user_manual and over limit" do
      create!(%{importance: 0.1, source: "user_manual"})
      create!(%{importance: 0.1, source: "user_manual"})

      # Both are user_manual — nothing to prune
      assert {:ok, 0} = Memory.prune_to_limit(1)
    end

    test "returns {:error, :memory_disabled} when disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} = Memory.prune_to_limit(100)
    end
  end

  # ── export_memories/1 ────────────────────────────────────────────────────────

  describe "export_memories/1" do
    test "returns {:ok, json_string} with all memories" do
      create!(%{content: "Fact one", memory_type: "fact", importance: 0.8})
      create!(%{content: "Pref one", memory_type: "preference", importance: 0.6})

      assert {:ok, json} = Memory.export_memories(:json)
      assert is_binary(json)

      {:ok, data} = Jason.decode(json)
      assert is_list(data)
      assert length(data) == 2

      contents = Enum.map(data, & &1["content"]) |> MapSet.new()
      assert MapSet.member?(contents, "Fact one")
      assert MapSet.member?(contents, "Pref one")
    end

    test "exported entries include all required fields" do
      create!(%{content: "Test fact", memory_type: "fact", importance: 0.7})

      assert {:ok, json} = Memory.export_memories(:json)
      {:ok, [entry]} = Jason.decode(json)

      assert Map.has_key?(entry, "content")
      assert Map.has_key?(entry, "memory_type")
      assert Map.has_key?(entry, "importance")
      assert Map.has_key?(entry, "source")
      assert Map.has_key?(entry, "inserted_at")
    end

    test "returns {:ok, \"[]\"} when no memories exist" do
      assert {:ok, "[]"} = Memory.export_memories(:json)
    end

    test "returns {:error, {:unsupported_format, :csv}} for unsupported formats" do
      assert {:error, {:unsupported_format, :csv}} = Memory.export_memories(:csv)
    end

    test "returns {:error, :memory_disabled} when disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} = Memory.export_memories(:json)
    end
  end

  # ── import_memories/2 ────────────────────────────────────────────────────────

  describe "import_memories/2" do
    test "imports valid JSON memories" do
      json =
        Jason.encode!([
          %{
            content: "Imported fact",
            memory_type: "fact",
            importance: 0.7,
            source: "user_manual"
          },
          %{
            content: "Imported pref",
            memory_type: "preference",
            importance: 0.5,
            source: "user_manual"
          }
        ])

      assert {:ok, %{imported: 2, failed: 0}} = Memory.import_memories(json)
      assert {:ok, entries} = Memory.list_memories()
      assert length(entries) == 2
    end

    test "defaults source to user_manual when not provided" do
      json = Jason.encode!([%{content: "No source", memory_type: "fact", importance: 0.5}])

      assert {:ok, %{imported: 1}} = Memory.import_memories(json)
      assert {:ok, [entry]} = Memory.list_memories()
      assert entry.source == "user_manual"
    end

    test "counts invalid entries in :failed" do
      json =
        Jason.encode!([
          %{content: "Valid", memory_type: "fact", source: "user_manual"},
          %{content: "", memory_type: "fact", source: "user_manual"}
        ])

      assert {:ok, %{imported: 1, failed: 1}} = Memory.import_memories(json)
    end

    test "returns {:error, {:invalid_format, _}} for non-array JSON" do
      assert {:error, {:invalid_format, _}} = Memory.import_memories(~s({"key": "val"}))
    end

    test "returns {:error, {:json_decode_error, _}} for invalid JSON" do
      assert {:error, {:json_decode_error, _}} = Memory.import_memories("not json")
    end

    test "round-trips with export_memories/1" do
      create!(%{content: "Round-trip fact", memory_type: "fact", importance: 0.8})

      assert {:ok, json} = Memory.export_memories(:json)

      # Clear and re-import
      Memory.delete_all_memories()
      assert {:ok, %{imported: 1}} = Memory.import_memories(json)

      assert {:ok, [entry]} = Memory.list_memories()
      assert entry.content == "Round-trip fact"
    end

    test "returns {:error, :memory_disabled} when disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, :memory_disabled} = Memory.import_memories("[]")
    end
  end

  # ── Memory.Manager GenServer ──────────────────────────────────────────────────

  describe "Memory.Manager" do
    test "starts successfully" do
      pid = start_supervised!({Manager, []})
      assert Process.alive?(pid)
    end

    test "run_maintenance_now/0 completes without error" do
      start_supervised!({Manager, []})
      # Should not raise
      assert :ok = Manager.run_maintenance_now()
      # Give the cast a moment to process
      _ = :sys.get_state(Manager)
    end

    test "maintenance runs decay and prune when memory is available" do
      start_supervised!({Manager, []})

      old_ts = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)
      create!(%{importance: 0.8, last_accessed_at: old_ts})

      assert :ok = Manager.run_maintenance_now()
      _ = :sys.get_state(Manager)

      assert {:ok, [entry]} = Memory.list_memories()
      assert entry.importance < 0.8
    end
  end
end

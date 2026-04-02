defmodule OllamaChat.MemoryTest do
  use OllamaChat.DataCase, async: true

  alias OllamaChat.Memory
  alias OllamaChat.Memory.Entry

  defp valid_memory_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        content: "User prefers Elixir",
        memory_type: "fact",
        source: "llm_explicit"
      },
      overrides
    )
  end

  defp create_memory!(overrides \\ %{}) do
    overrides
    |> valid_memory_attrs()
    |> Memory.create_memory!()
  end

  # ── Create ──────────────────────────────────────────────────────────────────

  describe "create_memory/1" do
    test "creates a memory entry with valid attrs" do
      attrs = valid_memory_attrs()
      assert {:ok, %Entry{} = entry} = Memory.create_memory(attrs)
      assert entry.content == "User prefers Elixir"
      assert entry.memory_type == "fact"
      assert entry.source == "llm_explicit"
      assert entry.id != nil
    end

    test "applies default values" do
      assert {:ok, %Entry{} = entry} = Memory.create_memory(valid_memory_attrs())
      assert entry.importance == 0.5
      assert entry.access_count == 0
      assert entry.metadata == %{}
      assert entry.category == nil
      assert entry.last_accessed_at == nil
      assert entry.conversation_id == nil
    end

    test "accepts all optional fields" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs =
        valid_memory_attrs(%{
          category: "programming",
          importance: 0.9,
          conversation_id: "conv-123",
          metadata: %{"key" => "value"},
          last_accessed_at: now
        })

      assert {:ok, %Entry{} = entry} = Memory.create_memory(attrs)
      assert entry.category == "programming"
      assert entry.importance == 0.9
      assert entry.conversation_id == "conv-123"
      assert entry.metadata == %{"key" => "value"}
      assert entry.last_accessed_at == now
    end

    test "requires content" do
      attrs = valid_memory_attrs(%{content: nil})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert "can't be blank" in errors_on(changeset).content
    end

    test "requires memory_type" do
      attrs = valid_memory_attrs(%{memory_type: nil})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert "can't be blank" in errors_on(changeset).memory_type
    end

    test "requires source" do
      attrs = valid_memory_attrs(%{source: nil})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert "can't be blank" in errors_on(changeset).source
    end

    test "validates memory_type inclusion" do
      attrs = valid_memory_attrs(%{memory_type: "invalid"})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert "is invalid" in errors_on(changeset).memory_type
    end

    test "accepts all valid memory_types" do
      for type <- ~w(fact preference context episodic) do
        attrs = valid_memory_attrs(%{memory_type: type, content: "type: #{type}"})
        assert {:ok, %Entry{memory_type: ^type}} = Memory.create_memory(attrs)
      end
    end

    test "validates source inclusion" do
      attrs = valid_memory_attrs(%{source: "unknown_source"})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert "is invalid" in errors_on(changeset).source
    end

    test "accepts all valid sources" do
      for source <- ~w(auto_extract llm_explicit user_manual) do
        attrs = valid_memory_attrs(%{source: source, content: "source: #{source}"})
        assert {:ok, %Entry{source: ^source}} = Memory.create_memory(attrs)
      end
    end

    test "validates importance is at least 0.0" do
      attrs = valid_memory_attrs(%{importance: -0.1})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert errors_on(changeset).importance != []
    end

    test "validates importance is at most 1.0" do
      attrs = valid_memory_attrs(%{importance: 1.1})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert errors_on(changeset).importance != []
    end

    test "accepts importance at boundaries 0.0 and 1.0" do
      assert {:ok, %Entry{importance: importance}} =
               Memory.create_memory(valid_memory_attrs(%{importance: 0.0, content: "low"}))

      assert importance == 0.0

      assert {:ok, %Entry{importance: 1.0}} =
               Memory.create_memory(valid_memory_attrs(%{importance: 1.0, content: "high"}))
    end

    test "validates content is not empty string" do
      attrs = valid_memory_attrs(%{content: ""})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert errors_on(changeset).content != []
    end

    test "validates category max length" do
      long_category = String.duplicate("a", 51)
      attrs = valid_memory_attrs(%{category: long_category})
      assert {:error, changeset} = Memory.create_memory(attrs)
      assert errors_on(changeset).category != []
    end

    test "accepts category at max length 50" do
      category = String.duplicate("a", 50)
      attrs = valid_memory_attrs(%{category: category})
      assert {:ok, %Entry{category: ^category}} = Memory.create_memory(attrs)
    end
  end

  describe "create_memory!/1" do
    test "creates a memory entry with valid attrs" do
      attrs = valid_memory_attrs()
      assert %Entry{} = entry = Memory.create_memory!(attrs)
      assert entry.content == "User prefers Elixir"
    end

    test "raises on invalid attrs" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        Memory.create_memory!(%{content: nil})
      end
    end
  end

  # ── Read ────────────────────────────────────────────────────────────────────

  describe "get_memory/1" do
    test "returns memory by ID" do
      entry = create_memory!()
      assert %Entry{id: id} = Memory.get_memory(entry.id)
      assert id == entry.id
    end

    test "returns nil for non-existent ID" do
      assert Memory.get_memory(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_memory!/1" do
    test "returns memory by ID" do
      entry = create_memory!()
      assert %Entry{} = Memory.get_memory!(entry.id)
    end

    test "raises for non-existent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Memory.get_memory!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_memories/1" do
    test "returns all memories ordered by importance desc, then updated_at desc" do
      _low = create_memory!(%{importance: 0.2, content: "low"})
      _high = create_memory!(%{importance: 0.9, content: "high"})
      _mid = create_memory!(%{importance: 0.5, content: "mid"})

      entries = Memory.list_memories()
      importances = Enum.map(entries, & &1.importance)
      assert importances == [0.9, 0.5, 0.2]
    end

    test "returns empty list when no memories" do
      assert Memory.list_memories() == []
    end

    test "filters by memory_type" do
      create_memory!(%{memory_type: "fact", content: "a fact"})
      create_memory!(%{memory_type: "preference", content: "a pref"})

      entries = Memory.list_memories(memory_type: "fact")
      assert length(entries) == 1
      assert hd(entries).memory_type == "fact"
    end

    test "filters by category" do
      create_memory!(%{category: "programming", content: "elixir stuff"})
      create_memory!(%{category: "food", content: "likes pizza"})
      create_memory!(%{content: "no category"})

      entries = Memory.list_memories(category: "programming")
      assert length(entries) == 1
      assert hd(entries).category == "programming"
    end

    test "filters by source" do
      create_memory!(%{source: "auto_extract", content: "auto"})
      create_memory!(%{source: "user_manual", content: "manual"})

      entries = Memory.list_memories(source: "user_manual")
      assert length(entries) == 1
      assert hd(entries).source == "user_manual"
    end

    test "filters by min_importance" do
      create_memory!(%{importance: 0.3, content: "low"})
      create_memory!(%{importance: 0.7, content: "high"})
      create_memory!(%{importance: 0.9, content: "highest"})

      entries = Memory.list_memories(min_importance: 0.7)
      assert length(entries) == 2
      assert Enum.all?(entries, fn e -> e.importance >= 0.7 end)
    end

    test "respects limit" do
      for i <- 1..5, do: create_memory!(%{content: "memory #{i}"})

      entries = Memory.list_memories(limit: 3)
      assert length(entries) == 3
    end

    test "respects offset" do
      for i <- 1..5 do
        create_memory!(%{content: "memory #{i}", importance: i / 10.0})
      end

      all = Memory.list_memories(limit: 50)
      offset_entries = Memory.list_memories(limit: 50, offset: 2)
      assert length(offset_entries) == 3
      assert offset_entries == Enum.drop(all, 2)
    end

    test "combines multiple filters" do
      create_memory!(%{
        memory_type: "fact",
        source: "llm_explicit",
        importance: 0.8,
        content: "target"
      })

      create_memory!(%{
        memory_type: "fact",
        source: "auto_extract",
        importance: 0.8,
        content: "wrong source"
      })

      create_memory!(%{
        memory_type: "preference",
        source: "llm_explicit",
        importance: 0.8,
        content: "wrong type"
      })

      entries =
        Memory.list_memories(
          memory_type: "fact",
          source: "llm_explicit",
          min_importance: 0.7
        )

      assert length(entries) == 1
      assert hd(entries).content == "target"
    end
  end

  describe "count_memories/1" do
    test "returns 0 when no memories" do
      assert Memory.count_memories() == 0
    end

    test "returns correct count" do
      for i <- 1..3, do: create_memory!(%{content: "memory #{i}"})
      assert Memory.count_memories() == 3
    end

    test "respects filters" do
      create_memory!(%{memory_type: "fact", content: "fact 1"})
      create_memory!(%{memory_type: "fact", content: "fact 2"})
      create_memory!(%{memory_type: "preference", content: "pref 1"})

      assert Memory.count_memories(memory_type: "fact") == 2
      assert Memory.count_memories(memory_type: "preference") == 1
      assert Memory.count_memories(memory_type: "episodic") == 0
    end

    test "filters by min_importance" do
      create_memory!(%{importance: 0.3, content: "low"})
      create_memory!(%{importance: 0.8, content: "high"})

      assert Memory.count_memories(min_importance: 0.5) == 1
    end
  end

  # ── Update ──────────────────────────────────────────────────────────────────

  describe "update_memory/2" do
    test "updates content" do
      entry = create_memory!()
      assert {:ok, updated} = Memory.update_memory(entry, %{content: "Updated content"})
      assert updated.content == "Updated content"
      assert updated.id == entry.id
    end

    test "updates importance" do
      entry = create_memory!(%{importance: 0.5})
      assert {:ok, updated} = Memory.update_memory(entry, %{importance: 0.9})
      assert updated.importance == 0.9
    end

    test "updates category" do
      entry = create_memory!()
      assert {:ok, updated} = Memory.update_memory(entry, %{category: "new-cat"})
      assert updated.category == "new-cat"
    end

    test "updates metadata" do
      entry = create_memory!()
      new_meta = %{"source_msg" => "abc123"}
      assert {:ok, updated} = Memory.update_memory(entry, %{metadata: new_meta})
      assert updated.metadata == new_meta
    end

    test "validates importance range on update" do
      entry = create_memory!()
      assert {:error, changeset} = Memory.update_memory(entry, %{importance: 1.5})
      assert errors_on(changeset).importance != []
    end

    test "validates content not empty on update" do
      entry = create_memory!()
      assert {:error, changeset} = Memory.update_memory(entry, %{content: ""})
      assert errors_on(changeset).content != []
    end

    test "validates memory_type on update" do
      entry = create_memory!()
      assert {:error, changeset} = Memory.update_memory(entry, %{memory_type: "bogus"})
      assert "is invalid" in errors_on(changeset).memory_type
    end

    test "validates category max length on update" do
      entry = create_memory!()
      long_cat = String.duplicate("x", 51)
      assert {:error, changeset} = Memory.update_memory(entry, %{category: long_cat})
      assert errors_on(changeset).category != []
    end

    test "persists update to database" do
      entry = create_memory!(%{content: "original"})
      {:ok, _updated} = Memory.update_memory(entry, %{content: "changed"})

      reloaded = Memory.get_memory!(entry.id)
      assert reloaded.content == "changed"
    end
  end

  # ── Touch ───────────────────────────────────────────────────────────────────

  describe "touch_memory/1" do
    test "increments access_count" do
      entry = create_memory!()
      assert entry.access_count == 0

      {:ok, touched} = Memory.touch_memory(entry)
      assert touched.access_count == 1
    end

    test "sets last_accessed_at" do
      entry = create_memory!()
      assert entry.last_accessed_at == nil

      {:ok, touched} = Memory.touch_memory(entry)
      assert touched.last_accessed_at != nil
      assert %DateTime{} = touched.last_accessed_at
    end

    test "increments multiple times" do
      entry = create_memory!()
      {:ok, touched1} = Memory.touch_memory(entry)
      {:ok, touched2} = Memory.touch_memory(touched1)

      assert touched2.access_count == 2
    end
  end

  describe "touch_memories/1" do
    test "batch updates multiple memories" do
      e1 = create_memory!(%{content: "first"})
      e2 = create_memory!(%{content: "second"})
      _e3 = create_memory!(%{content: "third, untouched"})

      assert {2, _} = Memory.touch_memories([e1.id, e2.id])

      updated1 = Memory.get_memory!(e1.id)
      updated2 = Memory.get_memory!(e2.id)

      assert updated1.access_count == 1
      assert updated2.access_count == 1
      assert updated1.last_accessed_at != nil
      assert updated2.last_accessed_at != nil
    end

    test "does not touch memories not in the list" do
      e1 = create_memory!(%{content: "touched"})
      e2 = create_memory!(%{content: "untouched"})

      Memory.touch_memories([e1.id])

      untouched = Memory.get_memory!(e2.id)
      assert untouched.access_count == 0
      assert untouched.last_accessed_at == nil
    end

    test "returns {0, nil} for empty list" do
      assert {0, nil} = Memory.touch_memories([])
    end
  end

  # ── Reinforce ───────────────────────────────────────────────────────────────

  describe "reinforce_memory/2" do
    test "boosts importance by default amount" do
      entry = create_memory!(%{importance: 0.5})
      assert {:ok, reinforced} = Memory.reinforce_memory(entry)
      assert_in_delta reinforced.importance, 0.6, 0.001
    end

    test "boosts importance by custom amount" do
      entry = create_memory!(%{importance: 0.5})
      assert {:ok, reinforced} = Memory.reinforce_memory(entry, 0.3)
      assert_in_delta reinforced.importance, 0.8, 0.001
    end

    test "clamps importance at 1.0" do
      entry = create_memory!(%{importance: 0.95})
      assert {:ok, reinforced} = Memory.reinforce_memory(entry, 0.2)
      assert reinforced.importance == 1.0
    end

    test "clamps at 1.0 even with large boost" do
      entry = create_memory!(%{importance: 0.1})
      assert {:ok, reinforced} = Memory.reinforce_memory(entry, 5.0)
      assert reinforced.importance == 1.0
    end

    test "persists reinforced importance" do
      entry = create_memory!(%{importance: 0.5})
      {:ok, _} = Memory.reinforce_memory(entry, 0.2)

      reloaded = Memory.get_memory!(entry.id)
      assert_in_delta reloaded.importance, 0.7, 0.001
    end
  end

  # ── Delete ──────────────────────────────────────────────────────────────────

  describe "delete_memory/1" do
    test "deletes a memory entry" do
      entry = create_memory!()
      assert {:ok, %Entry{}} = Memory.delete_memory(entry)
      assert Memory.get_memory(entry.id) == nil
    end
  end

  describe "delete_memory_by_id/1" do
    test "deletes a memory entry by ID" do
      entry = create_memory!()
      assert {:ok, %Entry{}} = Memory.delete_memory_by_id(entry.id)
      assert Memory.get_memory(entry.id) == nil
    end

    test "returns error tuple for non-existent ID" do
      assert {:error, :not_found} = Memory.delete_memory_by_id(Ecto.UUID.generate())
    end
  end

  describe "delete_all_memories/0" do
    test "deletes all memories" do
      for i <- 1..5, do: create_memory!(%{content: "memory #{i}"})
      assert Memory.count_memories() == 5

      assert {:ok, 5} = Memory.delete_all_memories()
      assert Memory.count_memories() == 0
    end

    test "returns 0 when no memories exist" do
      assert {:ok, 0} = Memory.delete_all_memories()
    end
  end

  # ── Search ──────────────────────────────────────────────────────────────────

  describe "search_by_text/2" do
    test "finds memories matching search term" do
      create_memory!(%{content: "User likes Elixir programming"})
      create_memory!(%{content: "User enjoys cooking"})
      create_memory!(%{content: "Elixir is a functional language"})

      results = Memory.search_by_text("Elixir")
      assert length(results) == 2
      assert Enum.all?(results, fn e -> String.contains?(e.content, "Elixir") end)
    end

    test "returns empty list when no matches" do
      create_memory!(%{content: "User likes Elixir"})
      assert Memory.search_by_text("Python") == []
    end

    test "search is case insensitive" do
      create_memory!(%{content: "User likes ELIXIR programming"})

      results = Memory.search_by_text("elixir")
      assert length(results) == 1

      results = Memory.search_by_text("ELIXIR")
      assert length(results) == 1
    end

    test "finds partial matches" do
      create_memory!(%{content: "Programming in Elixir is fun"})

      results = Memory.search_by_text("Program")
      assert length(results) == 1
    end

    test "respects limit option" do
      for i <- 1..5, do: create_memory!(%{content: "Elixir fact #{i}"})

      results = Memory.search_by_text("Elixir", limit: 2)
      assert length(results) == 2
    end

    test "orders results by importance then recency" do
      create_memory!(%{content: "Elixir low", importance: 0.2})
      create_memory!(%{content: "Elixir high", importance: 0.9})

      results = Memory.search_by_text("Elixir")
      assert hd(results).importance == 0.9
    end

    test "applies additional filters" do
      create_memory!(%{content: "Elixir fact", memory_type: "fact"})
      create_memory!(%{content: "Elixir preference", memory_type: "preference"})

      results = Memory.search_by_text("Elixir", memory_type: "fact")
      assert length(results) == 1
      assert hd(results).memory_type == "fact"
    end

    test "handles special LIKE characters in search" do
      create_memory!(%{content: "100% complete"})
      create_memory!(%{content: "something else"})

      results = Memory.search_by_text("100%")
      assert length(results) == 1
      assert hd(results).content == "100% complete"
    end
  end

  # ── Retrieval ───────────────────────────────────────────────────────────────

  describe "retrieve_relevant/1" do
    test "returns memories ordered by importance" do
      create_memory!(%{content: "low importance", importance: 0.2})
      create_memory!(%{content: "high importance", importance: 0.9})
      create_memory!(%{content: "mid importance", importance: 0.5})

      results = Memory.retrieve_relevant()
      importances = Enum.map(results, & &1.importance)
      assert importances == [0.9, 0.5, 0.2]
    end

    test "respects limit option" do
      for i <- 1..10, do: create_memory!(%{content: "memory #{i}"})

      results = Memory.retrieve_relevant(limit: 3)
      assert length(results) == 3
    end

    test "defaults to limit of 10" do
      for i <- 1..15, do: create_memory!(%{content: "memory #{i}"})

      results = Memory.retrieve_relevant()
      assert length(results) == 10
    end

    test "filters by memory_type" do
      create_memory!(%{content: "a fact", memory_type: "fact"})
      create_memory!(%{content: "a pref", memory_type: "preference"})

      results = Memory.retrieve_relevant(memory_type: "fact")
      assert length(results) == 1
      assert hd(results).memory_type == "fact"
    end

    test "filters by min_importance" do
      create_memory!(%{content: "low", importance: 0.2})
      create_memory!(%{content: "high", importance: 0.8})

      results = Memory.retrieve_relevant(min_importance: 0.5)
      assert length(results) == 1
      assert hd(results).importance == 0.8
    end

    test "returns empty list when no memories" do
      assert Memory.retrieve_relevant() == []
    end

    test "considers last_accessed_at in ordering for same importance" do
      old_time = ~U[2024-01-01 00:00:00Z]
      new_time = ~U[2024-06-01 00:00:00Z]

      e1 = create_memory!(%{content: "older access", importance: 0.5})
      e2 = create_memory!(%{content: "newer access", importance: 0.5})

      # Directly set last_accessed_at with controlled timestamps to avoid sleeps.
      # PostgreSQL sorts NULLs first in DESC, so both must be non-nil.
      Repo.update_all(
        from(m in Entry, where: m.id == ^e1.id),
        set: [last_accessed_at: old_time, access_count: 1]
      )

      Repo.update_all(
        from(m in Entry, where: m.id == ^e2.id),
        set: [last_accessed_at: new_time, access_count: 1]
      )

      results = Memory.retrieve_relevant()
      contents = Enum.map(results, & &1.content)

      # e2 was accessed more recently, so it should come first among same-importance entries
      assert hd(contents) == "newer access"

      # e1 is still in the list
      assert e1.content in contents
    end
  end

  # ── Format ──────────────────────────────────────────────────────────────────

  describe "format_for_prompt/1" do
    test "returns nil for empty list" do
      assert Memory.format_for_prompt([]) == nil
    end

    test "formats single memory entry" do
      entry = create_memory!(%{content: "User prefers Elixir", importance: 0.9})
      result = Memory.format_for_prompt([entry])

      assert is_binary(result)
      assert result =~ "## Your Memory"
      assert result =~ "User prefers Elixir"
      assert result =~ "high importance"
      assert result =~ "fact"
    end

    test "includes importance labels correctly" do
      high = create_memory!(%{content: "High importance", importance: 0.9})
      mid = create_memory!(%{content: "Medium importance", importance: 0.6})
      low = create_memory!(%{content: "Low importance", importance: 0.3})

      result = Memory.format_for_prompt([high, mid, low])

      assert result =~ "High importance (high importance"
      assert result =~ "Medium importance (medium importance"
      assert result =~ "Low importance (low importance"
    end

    test "formats importance at boundaries" do
      at_80 = create_memory!(%{content: "At 0.8", importance: 0.8})
      at_50 = create_memory!(%{content: "At 0.5", importance: 0.5})
      at_49 = create_memory!(%{content: "At 0.49", importance: 0.49})

      result = Memory.format_for_prompt([at_80, at_50, at_49])

      assert result =~ "At 0.8 (high importance"
      assert result =~ "At 0.5 (medium importance"
      assert result =~ "At 0.49 (low importance"
    end

    test "includes date learned" do
      entry = create_memory!(%{content: "a fact"})
      result = Memory.format_for_prompt([entry])

      # The date should be formatted like "Jan 5", "Dec 12", etc.
      # Just check that "learned" is present, as the exact date depends on when the test runs
      assert result =~ "learned "
    end

    test "includes memory type in each line" do
      fact = create_memory!(%{content: "A fact", memory_type: "fact"})

      pref =
        create_memory!(%{
          content: "A preference",
          memory_type: "preference",
          source: "user_manual"
        })

      result = Memory.format_for_prompt([fact, pref])

      assert result =~ "· fact ·"
      assert result =~ "· preference ·"
    end

    test "formats each memory as a bullet line" do
      e1 = create_memory!(%{content: "First memory"})
      e2 = create_memory!(%{content: "Second memory", source: "user_manual"})

      result = Memory.format_for_prompt([e1, e2])

      lines =
        result
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- "))

      assert length(lines) == 2
    end

    test "includes instructions about memory tools" do
      entry = create_memory!(%{content: "Something"})
      result = Memory.format_for_prompt([entry])

      assert result =~ "memory_save"
      assert result =~ "memory_update"
      assert result =~ "memory_delete"
    end
  end

  # ── Stats ───────────────────────────────────────────────────────────────────

  describe "stats/0" do
    test "returns correct structure" do
      stats = Memory.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total)
      assert Map.has_key?(stats, :by_type)
      assert Map.has_key?(stats, :by_source)
      assert Map.has_key?(stats, :average_importance)
    end

    test "returns zeroes for empty database" do
      stats = Memory.stats()

      assert stats.total == 0
      assert stats.by_type == %{}
      assert stats.by_source == %{}
      assert stats.average_importance == 0.0
    end

    test "returns correct counts by type" do
      create_memory!(%{memory_type: "fact", content: "fact 1"})
      create_memory!(%{memory_type: "fact", content: "fact 2"})
      create_memory!(%{memory_type: "preference", content: "pref 1"})
      create_memory!(%{memory_type: "episodic", content: "ep 1"})

      stats = Memory.stats()

      assert stats.total == 4
      assert stats.by_type["fact"] == 2
      assert stats.by_type["preference"] == 1
      assert stats.by_type["episodic"] == 1
      assert stats.by_type["context"] == nil
    end

    test "returns correct counts by source" do
      create_memory!(%{source: "llm_explicit", content: "llm 1"})
      create_memory!(%{source: "llm_explicit", content: "llm 2"})
      create_memory!(%{source: "user_manual", content: "manual 1"})

      stats = Memory.stats()

      assert stats.by_source["llm_explicit"] == 2
      assert stats.by_source["user_manual"] == 1
      assert stats.by_source["auto_extract"] == nil
    end

    test "calculates average importance" do
      create_memory!(%{importance: 0.2, content: "low"})
      create_memory!(%{importance: 0.8, content: "high"})

      stats = Memory.stats()

      assert_in_delta stats.average_importance, 0.5, 0.01
    end

    test "rounds average importance to 2 decimal places" do
      create_memory!(%{importance: 0.3, content: "a"})
      create_memory!(%{importance: 0.3, content: "b"})
      create_memory!(%{importance: 0.7, content: "c"})

      stats = Memory.stats()

      # (0.3 + 0.3 + 0.7) / 3 = 0.4333... -> 0.43
      assert_in_delta stats.average_importance, 0.43, 0.01
    end
  end
end

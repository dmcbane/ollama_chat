defmodule OllamaChat.BuiltinToolsTest do
  use OllamaChat.DataCase, async: false

  alias OllamaChat.BuiltinTools.Memory.Delete
  alias OllamaChat.BuiltinTools.Memory.List
  alias OllamaChat.BuiltinTools.Memory.Save
  alias OllamaChat.BuiltinTools.Memory.Search
  alias OllamaChat.BuiltinTools.Memory.Update
  alias OllamaChat.BuiltinTools.Registry
  alias OllamaChat.Memory

  @fake_embedding Enum.map(1..768, fn i -> :math.sin(i / 100) end)

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_memory!(overrides \\ %{}) do
    %{
      content: "User prefers Elixir",
      memory_type: "fact",
      source: "llm_explicit"
    }
    |> Map.merge(overrides)
    |> Memory.create_memory!()
  end

  # ── Registry ─────────────────────────────────────────────────────────────────

  describe "Registry" do
    test "list_tools/0 returns all 5 memory tool modules" do
      tools = Registry.list_tools()
      assert length(tools) == 5
      names = Enum.map(tools, & &1.name())
      assert "memory_save" in names
      assert "memory_search" in names
      assert "memory_update" in names
      assert "memory_delete" in names
      assert "memory_list" in names
    end

    test "get_tool/1 returns the correct module by name" do
      assert Registry.get_tool("memory_save") == Save
      assert Registry.get_tool("memory_search") == Search
      assert Registry.get_tool("memory_update") == Update
      assert Registry.get_tool("memory_delete") == Delete
      assert Registry.get_tool("memory_list") == List
    end

    test "get_tool/1 returns nil for unknown tool name" do
      assert Registry.get_tool("nonexistent_tool") == nil
      assert Registry.get_tool("") == nil
    end

    test "builtin_tool?/1 returns true for registered tools" do
      assert Registry.builtin_tool?("memory_save")
      assert Registry.builtin_tool?("memory_search")
      assert Registry.builtin_tool?("memory_update")
      assert Registry.builtin_tool?("memory_delete")
      assert Registry.builtin_tool?("memory_list")
    end

    test "builtin_tool?/1 returns false for unknown tools" do
      refute Registry.builtin_tool?("read_file")
      refute Registry.builtin_tool?("unknown")
      refute Registry.builtin_tool?("")
    end

    test "tool_schemas/0 returns a list with name, description, and parameters keys" do
      schemas = Registry.tool_schemas()
      assert length(schemas) == 5

      for schema <- schemas do
        assert is_binary(schema["name"])
        assert String.length(schema["name"]) > 0
        assert is_binary(schema["description"])
        assert String.length(schema["description"]) > 0
        assert is_map(schema["parameters"])
        assert schema["parameters"]["type"] == "object"
      end
    end

    test "each tool module has a non-empty name" do
      for tool <- Registry.list_tools() do
        name = tool.name()
        assert is_binary(name)
        assert String.length(name) > 0
        assert Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name), "Invalid tool name: #{name}"
      end
    end

    test "each tool module has a non-empty description" do
      for tool <- Registry.list_tools() do
        desc = tool.description()
        assert is_binary(desc)
        assert String.length(desc) > 0
      end
    end

    test "each tool module has a valid parameters schema" do
      for tool <- Registry.list_tools() do
        schema = tool.parameters_schema()
        assert is_map(schema)
        assert schema["type"] == "object"
        assert is_map(schema["properties"])
      end
    end
  end

  # ── Memory.Save ──────────────────────────────────────────────────────────────

  describe "Memory.Save" do
    test "name/0 returns 'memory_save'" do
      assert Save.name() == "memory_save"
    end

    test "execute/1 creates a memory entry with required content only" do
      assert {:ok, result} = Save.execute(%{"content" => "User likes dark mode"})
      assert result =~ "Memory saved"
      assert result =~ "User likes dark mode"
      assert result =~ "fact"
    end

    test "execute/1 includes the generated id in the result" do
      assert {:ok, result} = Save.execute(%{"content" => "User works remotely"})
      assert result =~ "id:"
    end

    test "execute/1 accepts all optional fields" do
      args = %{
        "content" => "User prefers Elixir over Python",
        "memory_type" => "preference",
        "category" => "programming",
        "importance" => 0.8
      }

      assert {:ok, result} = Save.execute(args)
      assert result =~ "preference"
      assert result =~ "high"
    end

    test "execute/1 persists the entry to the database" do
      {:ok, _} = Save.execute(%{"content" => "User is a Phoenix developer"})

      assert {:ok, entries} = Memory.list_memories()
      assert Enum.any?(entries, &String.contains?(&1.content, "Phoenix developer"))
    end

    test "execute/1 defaults memory_type to 'fact'" do
      {:ok, _} = Save.execute(%{"content" => "User has two cats"})
      assert {:ok, entries} = Memory.list_memories()

      entry = Enum.find(entries, &String.contains?(&1.content, "two cats"))
      assert entry.memory_type == "fact"
    end

    test "execute/1 defaults importance to 0.5" do
      {:ok, _} = Save.execute(%{"content" => "User enjoys hiking"})
      assert {:ok, entries} = Memory.list_memories()

      entry = Enum.find(entries, &String.contains?(&1.content, "hiking"))
      assert entry.importance == 0.5
    end

    test "execute/1 clamps importance values outside 0.0–1.0 range" do
      {:ok, _} = Save.execute(%{"content" => "clamped high", "importance" => 1.5})
      {:ok, _} = Save.execute(%{"content" => "clamped low", "importance" => -0.5})

      assert {:ok, entries} = Memory.list_memories()
      high = Enum.find(entries, &String.contains?(&1.content, "clamped high"))
      low = Enum.find(entries, &String.contains?(&1.content, "clamped low"))

      assert high.importance <= 1.0
      assert low.importance >= 0.0
    end

    test "execute/1 returns error when content is missing" do
      assert {:error, msg} = Save.execute(%{})
      assert msg =~ "content"
    end

    test "execute/1 returns error when content is empty string" do
      assert {:error, msg} = Save.execute(%{"content" => ""})
      assert msg =~ "content"
    end

    test "execute/1 returns error when memory_type is invalid" do
      assert {:error, msg} = Save.execute(%{"content" => "test", "memory_type" => "invalid_type"})
      assert is_binary(msg)
    end

    test "execute/1 returns error when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, msg} = Save.execute(%{"content" => "test"})
      assert msg =~ "disabled"
    end
  end

  # ── Memory.Search ─────────────────────────────────────────────────────────────

  describe "Memory.Search" do
    test "name/0 returns 'memory_search'" do
      assert Search.name() == "memory_search"
    end

    test "execute/1 finds matching memories via full-text search" do
      create_memory!(%{content: "User is a professional Elixir developer"})

      assert {:ok, result} = Search.execute(%{"query" => "Elixir developer"})
      assert result =~ "Elixir developer"
      assert result =~ "id:"
    end

    test "execute/1 returns empty-results message when nothing matches" do
      assert {:ok, result} = Search.execute(%{"query" => "zzz_no_match_xyz"})
      assert result =~ "No memories found"
    end

    test "execute/1 respects the limit parameter" do
      for i <- 1..5, do: create_memory!(%{content: "Test search memory #{i}"})

      assert {:ok, result} = Search.execute(%{"query" => "search memory", "limit" => 2})
      # Should find at most 2 results; count bullet points
      line_count = result |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "- "))
      assert line_count <= 2
    end

    test "execute/1 applies memory_type filter" do
      create_memory!(%{content: "Fact about Elixir", memory_type: "fact"})
      create_memory!(%{content: "Preference about Elixir", memory_type: "preference"})

      assert {:ok, result} =
               Search.execute(%{"query" => "Elixir", "memory_type" => "preference"})

      assert result =~ "preference"
    end

    test "execute/1 includes memory id in each result line" do
      create_memory!(%{content: "User works at a startup"})

      assert {:ok, result} = Search.execute(%{"query" => "startup"})
      assert result =~ "[id:"
    end

    test "execute/1 returns error when query is missing" do
      assert {:error, msg} = Search.execute(%{})
      assert msg =~ "query"
    end

    test "execute/1 returns error when query is empty" do
      assert {:error, msg} = Search.execute(%{"query" => "  "})
      assert msg =~ "query"
    end

    test "execute/1 returns error when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, msg} = Search.execute(%{"query" => "test"})
      assert msg =~ "disabled"
    end

    test "execute/1 uses embedding fallback when embedding_fn fails (full-text path)" do
      create_memory!(%{content: "User enjoys mountain biking"})

      # retrieve_relevant internally falls back to full-text on embedding failure
      # (Ollama won't be running during tests, so embedding will fail automatically)
      assert {:ok, result} = Search.execute(%{"query" => "mountain biking"})
      assert result =~ "mountain biking"
    end
  end

  # ── Memory.Update ─────────────────────────────────────────────────────────────

  describe "Memory.Update" do
    test "name/0 returns 'memory_update'" do
      assert Update.name() == "memory_update"
    end

    test "execute/1 updates the content of an existing memory" do
      entry = create_memory!(%{content: "User likes Python"})

      assert {:ok, result} =
               Update.execute(%{"id" => entry.id, "content" => "User likes Elixir now"})

      assert result =~ "updated"
      assert result =~ "Elixir now"

      assert {:ok, updated} = Memory.get_memory(entry.id)
      assert updated.content == "User likes Elixir now"
    end

    test "execute/1 updates importance" do
      entry = create_memory!(%{importance: 0.3})

      assert {:ok, _} = Update.execute(%{"id" => entry.id, "importance" => 0.9})

      assert {:ok, updated} = Memory.get_memory(entry.id)
      assert updated.importance == 0.9
    end

    test "execute/1 updates memory_type" do
      entry = create_memory!(%{memory_type: "fact"})

      assert {:ok, _} = Update.execute(%{"id" => entry.id, "memory_type" => "preference"})

      assert {:ok, updated} = Memory.get_memory(entry.id)
      assert updated.memory_type == "preference"
    end

    test "execute/1 updates category" do
      entry = create_memory!()

      assert {:ok, _} = Update.execute(%{"id" => entry.id, "category" => "work"})

      assert {:ok, updated} = Memory.get_memory(entry.id)
      assert updated.category == "work"
    end

    test "execute/1 returns error when id is missing" do
      assert {:error, msg} = Update.execute(%{"content" => "new content"})
      assert msg =~ "id"
    end

    test "execute/1 returns error when id is empty string" do
      assert {:error, msg} = Update.execute(%{"id" => ""})
      assert msg =~ "id"
    end

    test "execute/1 returns error when no update fields are provided" do
      entry = create_memory!()
      assert {:error, msg} = Update.execute(%{"id" => entry.id})
      assert msg =~ "at least one field"
    end

    test "execute/1 returns error for non-existent id" do
      fake_id = Ecto.UUID.generate()
      assert {:error, msg} = Update.execute(%{"id" => fake_id, "content" => "updated"})
      assert msg =~ "No memory found"
    end

    test "execute/1 returns error when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, msg} =
               Update.execute(%{"id" => Ecto.UUID.generate(), "content" => "test"})

      assert msg =~ "disabled"
    end

    test "execute/1 returns error for invalid memory_type" do
      entry = create_memory!()

      assert {:error, msg} =
               Update.execute(%{"id" => entry.id, "memory_type" => "nonsense"})

      assert is_binary(msg)
    end
  end

  # ── Memory.Delete ─────────────────────────────────────────────────────────────

  describe "Memory.Delete" do
    test "name/0 returns 'memory_delete'" do
      assert Delete.name() == "memory_delete"
    end

    test "execute/1 deletes an existing memory by id" do
      entry = create_memory!()

      assert {:ok, result} = Delete.execute(%{"id" => entry.id})
      assert result =~ "deleted"
      assert result =~ entry.id

      assert {:ok, nil} = Memory.get_memory(entry.id)
    end

    test "execute/1 returns error for non-existent id" do
      fake_id = Ecto.UUID.generate()
      assert {:error, msg} = Delete.execute(%{"id" => fake_id})
      assert msg =~ "No memory found"
    end

    test "execute/1 returns error when id is missing" do
      assert {:error, msg} = Delete.execute(%{})
      assert msg =~ "id"
    end

    test "execute/1 returns error when id is empty string" do
      assert {:error, msg} = Delete.execute(%{"id" => ""})
      assert msg =~ "empty"
    end

    test "execute/1 returns error when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, msg} = Delete.execute(%{"id" => Ecto.UUID.generate()})
      assert msg =~ "disabled"
    end
  end

  # ── Memory.List ───────────────────────────────────────────────────────────────

  describe "Memory.List" do
    test "name/0 returns 'memory_list'" do
      assert List.name() == "memory_list"
    end

    test "execute/1 lists all memories" do
      create_memory!(%{content: "User is a developer"})
      create_memory!(%{content: "User likes coffee"})

      assert {:ok, result} = List.execute(%{})
      assert result =~ "developer"
      assert result =~ "coffee"
    end

    test "execute/1 returns empty message when no memories exist" do
      assert {:ok, result} = List.execute(%{})
      assert result =~ "No memories found"
    end

    test "execute/1 filters by memory_type" do
      create_memory!(%{content: "A fact", memory_type: "fact"})
      create_memory!(%{content: "A preference", memory_type: "preference"})

      assert {:ok, result} = List.execute(%{"memory_type" => "fact"})
      assert result =~ "A fact"
      refute result =~ "A preference"
    end

    test "execute/1 respects the limit parameter" do
      for i <- 1..5, do: create_memory!(%{content: "List memory item #{i}"})

      assert {:ok, result} = List.execute(%{"limit" => 2})
      lines = result |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "- "))
      assert lines <= 2
    end

    test "execute/1 includes memory id in each result line" do
      create_memory!(%{content: "User is left-handed"})

      assert {:ok, result} = List.execute(%{})
      assert result =~ "[id:"
    end

    test "execute/1 includes importance and type metadata" do
      create_memory!(%{content: "User hates Mondays", importance: 0.9, memory_type: "preference"})

      assert {:ok, result} = List.execute(%{})
      assert result =~ "preference"
      assert result =~ "high"
    end

    test "execute/1 includes category when set" do
      create_memory!(%{content: "User leads a team", category: "work"})

      assert {:ok, result} = List.execute(%{})
      assert result =~ "work"
    end

    test "execute/1 works with no arguments (all optional)" do
      create_memory!()
      assert {:ok, result} = List.execute(%{})
      assert is_binary(result)
    end

    test "execute/1 returns empty-type message when filter matches nothing" do
      create_memory!(%{memory_type: "fact"})

      assert {:ok, result} = List.execute(%{"memory_type" => "episodic"})
      assert result =~ "No memories found"
      assert result =~ "episodic"
    end

    test "execute/1 returns error when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      assert {:error, msg} = List.execute(%{})
      assert msg =~ "disabled"
    end

    test "execute/1 with invalid limit falls back to default" do
      for i <- 1..3, do: create_memory!(%{content: "list item #{i}"})

      # Invalid limit should be treated as default (10), not error
      assert {:ok, result} = List.execute(%{"limit" => -1})
      assert is_binary(result)
    end
  end

  # ── BuiltinTool Behaviour Compliance ─────────────────────────────────────────

  describe "BuiltinTool behaviour compliance" do
    @tool_modules [Save, Search, Update, Delete, List]

    test "all tools implement the BuiltinTool behaviour" do
      for mod <- @tool_modules do
        attrs = mod.module_info(:attributes)
        behaviours = attrs |> Keyword.get_values(:behaviour) |> Enum.concat()

        assert OllamaChat.BuiltinTool in behaviours,
               "#{mod} does not implement OllamaChat.BuiltinTool"
      end
    end

    test "all tool names are unique" do
      names = Enum.map(@tool_modules, & &1.name())
      assert names == Enum.uniq(names), "Duplicate tool names detected: #{inspect(names)}"
    end

    test "execute/1 always returns {:ok, string} or {:error, string}" do
      # Spot-check: call execute with empty args and verify return shape
      for mod <- @tool_modules do
        result = mod.execute(%{})

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "#{mod}.execute/1 did not return {:ok, _} or {:error, _}"

        case result do
          {:ok, text} ->
            assert is_binary(text), "#{mod}.execute/1 :ok value must be a string"

          {:error, text} ->
            assert is_binary(text), "#{mod}.execute/1 :error value must be a string"
        end
      end
    end
  end
end

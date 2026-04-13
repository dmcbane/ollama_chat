defmodule OllamaChat.ToolRouterTest do
  use OllamaChat.DataCase, async: false

  alias OllamaChat.BuiltinTools.Registry, as: BuiltinRegistry
  alias OllamaChat.Memory
  alias OllamaChat.ToolPromptBuilder
  alias OllamaChat.ToolRouter

  # ── BuiltinTools.Registry ──────────────────────────────────────────────────

  describe "BuiltinTools.Registry.list_tools/0" do
    test "returns a non-empty list of tool modules" do
      tools = BuiltinRegistry.list_tools()
      assert is_list(tools)
      assert tools != []
    end

    test "all returned modules implement the BuiltinTool behaviour" do
      for tool <- BuiltinRegistry.list_tools() do
        assert is_binary(tool.name()),
               "#{inspect(tool)}.name() must return a string"

        assert is_binary(tool.description()),
               "#{inspect(tool)}.description() must return a string"

        assert is_map(tool.parameters_schema()),
               "#{inspect(tool)}.parameters_schema() must return a map"

        # execute/1 is verified by calling it with empty args — must return a tuple
        result = tool.execute(%{})

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "#{inspect(tool)}.execute/1 must return {:ok, _} or {:error, _}"
      end
    end

    test "includes all five memory tools" do
      names = BuiltinRegistry.list_tools() |> Enum.map(& &1.name())

      for expected <- ~w(memory_save memory_search memory_update memory_delete memory_list) do
        assert expected in names,
               "Expected #{expected} to be registered but got: #{inspect(names)}"
      end
    end

    test "all tool names are unique" do
      names = BuiltinRegistry.list_tools() |> Enum.map(& &1.name())
      assert names == Enum.uniq(names)
    end
  end

  describe "BuiltinTools.Registry.get_tool/1" do
    test "returns the module for a known tool name" do
      assert BuiltinRegistry.get_tool("memory_save") ==
               OllamaChat.BuiltinTools.Memory.Save

      assert BuiltinRegistry.get_tool("memory_search") ==
               OllamaChat.BuiltinTools.Memory.Search

      assert BuiltinRegistry.get_tool("memory_update") ==
               OllamaChat.BuiltinTools.Memory.Update

      assert BuiltinRegistry.get_tool("memory_delete") ==
               OllamaChat.BuiltinTools.Memory.Delete

      assert BuiltinRegistry.get_tool("memory_list") ==
               OllamaChat.BuiltinTools.Memory.List
    end

    test "returns nil for an unknown tool name" do
      assert BuiltinRegistry.get_tool("read_file") == nil
      assert BuiltinRegistry.get_tool("") == nil
      assert BuiltinRegistry.get_tool("nonexistent") == nil
    end
  end

  describe "BuiltinTools.Registry.builtin_tool?/1" do
    test "returns true for registered tool names" do
      assert BuiltinRegistry.builtin_tool?("memory_save")
      assert BuiltinRegistry.builtin_tool?("memory_search")
      assert BuiltinRegistry.builtin_tool?("memory_update")
      assert BuiltinRegistry.builtin_tool?("memory_delete")
      assert BuiltinRegistry.builtin_tool?("memory_list")
    end

    test "returns false for unregistered tool names" do
      refute BuiltinRegistry.builtin_tool?("read_file")
      refute BuiltinRegistry.builtin_tool?("write_file")
      refute BuiltinRegistry.builtin_tool?("")
      refute BuiltinRegistry.builtin_tool?("MEMORY_SAVE")
    end
  end

  describe "BuiltinTools.Registry.tool_schemas/0" do
    test "returns one schema map per tool" do
      schemas = BuiltinRegistry.tool_schemas()
      assert length(schemas) == length(BuiltinRegistry.list_tools())
    end

    test "each schema has required keys" do
      for schema <- BuiltinRegistry.tool_schemas() do
        assert Map.has_key?(schema, "name"), "schema missing 'name'"
        assert Map.has_key?(schema, "description"), "schema missing 'description'"
        assert Map.has_key?(schema, "parameters"), "schema missing 'parameters'"
        assert is_binary(schema["name"])
        assert is_binary(schema["description"])
        assert is_map(schema["parameters"])
      end
    end

    test "schema names match the tool module names" do
      schema_names = BuiltinRegistry.tool_schemas() |> Enum.map(& &1["name"])
      module_names = BuiltinRegistry.list_tools() |> Enum.map(& &1.name())
      assert Enum.sort(schema_names) == Enum.sort(module_names)
    end
  end

  # ── ToolRouter ────────────────────────────────────────────────────────────

  describe "ToolRouter.route_tool_call/2 with built-in tools" do
    test "routes memory_save to the built-in executor" do
      args = %{"content" => "User prefers dark mode", "memory_type" => "preference"}
      assert {:ok, result} = ToolRouter.route_tool_call("memory_save", args)
      assert String.contains?(result, "Memory saved")
      assert String.contains?(result, "User prefers dark mode")
    end

    test "routes memory_list to the built-in executor" do
      assert {:ok, result} = ToolRouter.route_tool_call("memory_list", %{})
      # Either "No memories found" or a formatted list
      assert is_binary(result)
    end

    test "routes memory_search to the built-in executor" do
      assert {:ok, result} = ToolRouter.route_tool_call("memory_search", %{"query" => "anything"})
      assert is_binary(result)
    end

    test "routes memory_delete for a non-existent id returns error tuple" do
      assert {:error, reason} =
               ToolRouter.route_tool_call("memory_delete", %{
                 "id" => "00000000-0000-0000-0000-000000000000"
               })

      assert is_binary(reason)
    end

    test "routes memory_update for a non-existent id returns error tuple" do
      assert {:error, reason} =
               ToolRouter.route_tool_call("memory_update", %{
                 "id" => "00000000-0000-0000-0000-000000000000",
                 "content" => "updated"
               })

      assert is_binary(reason)
    end
  end

  describe "ToolRouter.route_tool_call/2 with invalid input" do
    test "returns error for nil tool name" do
      assert {:error, _reason} = ToolRouter.route_tool_call(nil, %{})
    end

    test "returns error for non-string tool name" do
      assert {:error, _reason} = ToolRouter.route_tool_call(123, %{})
    end

    test "returns error or mcp-not-found for unknown tool name" do
      # Unknown tool is forwarded to MCPClient which will fail (MCP not running)
      result = ToolRouter.route_tool_call("unknown_tool_xyz", %{})
      # Must be an error tuple — either from MCPClient or the router itself
      assert {:error, _} = result
    end
  end

  describe "ToolRouter.known_tool?/2" do
    test "returns true for registered built-in tools" do
      assert ToolRouter.known_tool?("memory_save")
      assert ToolRouter.known_tool?("memory_list")
    end

    test "returns true when tool is in the mcp_tools map" do
      mcp_tools = %{"read_file" => %{description: "Read a file", schema: %{}}}
      assert ToolRouter.known_tool?("read_file", mcp_tools)
    end

    test "returns false when tool is unknown everywhere" do
      refute ToolRouter.known_tool?("totally_unknown_tool_xyz", %{})
    end

    test "returns false for empty string" do
      refute ToolRouter.known_tool?("", %{})
    end
  end

  # ── ToolPromptBuilder ─────────────────────────────────────────────────────

  describe "ToolPromptBuilder.any_tools_available?/1" do
    test "returns true when memory is available (DB connected, enabled)" do
      # Memory is available in the test environment (DataCase sets up the DB)
      assert ToolPromptBuilder.any_tools_available?(%{})
    end

    test "returns true when MCP tools are present even if memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      mcp_tools = %{"read_file" => %{description: "Read a file", schema: %{}}}
      assert ToolPromptBuilder.any_tools_available?(mcp_tools)
    end

    test "returns false when memory is disabled and no MCP tools" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      refute ToolPromptBuilder.any_tools_available?(%{})
    end
  end

  describe "ToolPromptBuilder.build_tool_aware_system_prompt/2" do
    test "returns a string" do
      result = ToolPromptBuilder.build_tool_aware_system_prompt(%{})
      assert is_binary(result)
    end

    test "includes built-in tool names when memory is available" do
      prompt = ToolPromptBuilder.build_tool_aware_system_prompt(%{})
      assert String.contains?(prompt, "memory_save")
      assert String.contains?(prompt, "memory_search")
      assert String.contains?(prompt, "memory_update")
      assert String.contains?(prompt, "memory_delete")
      assert String.contains?(prompt, "memory_list")
    end

    test "includes MCP tool names when provided" do
      mcp_tools = %{
        "read_file" => %{
          description: "Read a file",
          schema: %{"type" => "object", "properties" => %{}},
          requires_approval: false
        }
      }

      prompt = ToolPromptBuilder.build_tool_aware_system_prompt(mcp_tools)
      assert String.contains?(prompt, "read_file")
      assert String.contains?(prompt, "memory_save")
    end

    test "includes base_prompt when provided" do
      prompt = ToolPromptBuilder.build_tool_aware_system_prompt(%{}, "Be concise and helpful.")
      assert String.contains?(prompt, "Be concise and helpful.")
    end

    test "does not include memory tools when memory is disabled" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      mcp_tools = %{
        "read_file" => %{
          description: "Read a file",
          schema: %{"type" => "object", "properties" => %{}},
          requires_approval: false
        }
      }

      prompt = ToolPromptBuilder.build_tool_aware_system_prompt(mcp_tools)
      refute String.contains?(prompt, "memory_save")
      assert String.contains?(prompt, "read_file")
    end

    test "MCP tool overrides built-in tool of same name" do
      # If an MCP server provides a tool named "memory_save", it takes precedence
      mcp_override = %{
        "memory_save" => %{
          description: "Custom MCP memory_save override",
          schema: %{"type" => "object", "properties" => %{}},
          requires_approval: false
        }
      }

      prompt = ToolPromptBuilder.build_tool_aware_system_prompt(mcp_override)
      assert String.contains?(prompt, "Custom MCP memory_save override")
    end

    test "returns a non-empty prompt when no tools available and base_prompt nil" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)

      result = ToolPromptBuilder.build_tool_aware_system_prompt(%{})
      assert is_binary(result)
      assert String.length(result) > 0
    end
  end

  # ── Memory availability guard ─────────────────────────────────────────────

  describe "Memory.available?/0 in test environment" do
    test "returns true when memory is enabled and DB is connected" do
      assert Memory.available?()
    end

    test "returns false when memory_enabled is set to false" do
      Application.put_env(:ollama_chat, :memory_enabled, false)
      on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)
      refute Memory.available?()
    end
  end
end

defmodule OllamaChat.MCPClientTest do
  use ExUnit.Case, async: false

  alias OllamaChat.MCPClient
  alias OllamaChat.MCPRegistry

  describe "when MCP is disabled (default)" do
    test "enabled?/0 returns false" do
      refute MCPClient.enabled?()
    end

    test "list_tools/0 returns empty map" do
      assert {:ok, tools} = MCPClient.list_tools()
      assert tools == %{}
    end

    test "health_status/0 returns empty map" do
      assert health = MCPClient.health_status()
      assert health == %{}
    end

    test "call_tool/2 returns error for non-existent tool" do
      assert {:error, reason} = MCPClient.call_tool("nonexistent_tool", %{})
      assert reason =~ "Tool not found"
    end

    test "registry can be queried when MCP disabled" do
      # Registry may have data from other operations, but should be queryable
      assert is_integer(MCPRegistry.count())
      assert is_map(MCPRegistry.list_all_tools())
    end
  end

  describe "registry operations" do
    setup do
      # Clear registry before each test
      MCPRegistry.clear()
      :ok
    end

    test "register_tools/1 stores tools" do
      tools = %{
        "test_tool" => %{
          server: :test_server,
          name: "test_tool",
          description: "A test tool",
          schema: %{"type" => "object"},
          requires_approval: false
        }
      }

      assert :ok = MCPRegistry.register_tools(tools)
      assert MCPRegistry.count() == 1
    end

    test "get_tool/1 retrieves registered tool" do
      tools = %{
        "read_file" => %{
          server: :filesystem,
          name: "read_file",
          description: "Read a file",
          schema: %{},
          requires_approval: false
        }
      }

      MCPRegistry.register_tools(tools)

      assert tool = MCPRegistry.get_tool("read_file")
      assert tool.name == "read_file"
      assert tool.server == :filesystem
    end

    test "get_tool/1 returns nil for non-existent tool" do
      assert MCPRegistry.get_tool("nonexistent") == nil
    end

    test "tool_exists?/1 checks tool existence" do
      tools = %{"test_tool" => %{server: :test, name: "test_tool"}}
      MCPRegistry.register_tools(tools)

      assert MCPRegistry.tool_exists?("test_tool")
      refute MCPRegistry.tool_exists?("nonexistent")
    end

    test "list_all_tools/0 returns all registered tools" do
      tools = %{
        "tool1" => %{server: :server1, name: "tool1"},
        "tool2" => %{server: :server2, name: "tool2"}
      }

      MCPRegistry.register_tools(tools)

      all_tools = MCPRegistry.list_all_tools()
      assert map_size(all_tools) == 2
      assert Map.has_key?(all_tools, "tool1")
      assert Map.has_key?(all_tools, "tool2")
    end

    test "get_tools_by_server/1 filters by server" do
      tools = %{
        "fs_tool1" => %{server: :filesystem, name: "fs_tool1"},
        "fs_tool2" => %{server: :filesystem, name: "fs_tool2"},
        "time_tool" => %{server: :time, name: "time_tool"}
      }

      MCPRegistry.register_tools(tools)

      fs_tools = MCPRegistry.get_tools_by_server(:filesystem)
      assert length(fs_tools) == 2
      assert Enum.all?(fs_tools, fn tool -> tool.server == :filesystem end)

      time_tools = MCPRegistry.get_tools_by_server(:time)
      assert length(time_tools) == 1
    end

    test "summary/0 provides registry overview" do
      tools = %{
        "tool1" => %{server: :server1, name: "tool1"},
        "tool2" => %{server: :server2, name: "tool2"},
        "tool3" => %{server: :server1, name: "tool3"}
      }

      MCPRegistry.register_tools(tools)

      summary = MCPRegistry.summary()
      assert summary.total_tools == 3
      assert :server1 in summary.servers
      assert :server2 in summary.servers
      assert summary.last_update != nil
    end

    test "last_update/0 returns nil when never updated" do
      MCPRegistry.clear()
      assert MCPRegistry.last_update() == nil
    end

    test "last_update/0 returns timestamp after update" do
      tools = %{"test" => %{server: :test, name: "test"}}
      MCPRegistry.register_tools(tools)

      assert %DateTime{} = MCPRegistry.last_update()
    end

    test "clear/0 removes all tools" do
      tools = %{"test" => %{server: :test, name: "test"}}
      MCPRegistry.register_tools(tools)

      assert MCPRegistry.count() == 1

      MCPRegistry.clear()

      assert MCPRegistry.count() == 0
      assert MCPRegistry.list_all_tools() == %{}
      assert MCPRegistry.last_update() == nil
    end
  end

  # Integration tests - require actual MCP servers to be running
  # These are skipped by default and only run when explicitly enabled
  describe "integration with real MCP servers" do
    @describetag :mcp_integration
    @describetag :skip

    test "discovers tools from configured servers" do
      # This would require MCP servers to be running
      # and MCP to be enabled in test config
      assert {:ok, tools} = MCPClient.list_tools()
      assert is_map(tools)
      # Would check for specific tools based on test server config
    end

    @tag :skip
    test "executes tool call successfully" do
      # This would test actual tool execution
      # Requires MCP server with known tools
      assert {:ok, result} = MCPClient.call_tool("test_tool", %{})
      assert is_list(result)
    end

    @tag :skip
    test "handles tool execution errors gracefully" do
      # Test error handling with invalid tool calls
      assert {:error, _reason} = MCPClient.call_tool("test_tool", %{invalid: "args"})
    end

    @tag :skip
    test "health_status/0 reports server status" do
      status = MCPClient.health_status()
      assert is_map(status)
      # Would verify status structure for each configured server
    end
  end

  describe "refresh_tools/0" do
    test "sends refresh message" do
      # Test that refresh_tools returns :ok
      # Actual refresh happens asynchronously
      assert :ok = MCPClient.refresh_tools()
    end
  end
end

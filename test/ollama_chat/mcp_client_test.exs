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

    test "list_server_configs/0 returns empty list" do
      assert MCPClient.list_server_configs() == []
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

  describe "dynamic server management" do
    setup do
      # Use a temp directory for config persistence so tests don't pollute real config
      tmp_dir =
        Path.join(System.tmp_dir!(), "mcp_client_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      config_path = Path.join(tmp_dir, "mcp_servers.json")

      original_path = Application.get_env(:ollama_chat, :mcp_config_path)
      Application.put_env(:ollama_chat, :mcp_config_path, config_path)

      on_exit(fn ->
        if original_path do
          Application.put_env(:ollama_chat, :mcp_config_path, original_path)
        else
          Application.delete_env(:ollama_chat, :mcp_config_path)
        end

        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir, config_path: config_path}
    end

    test "add_server/1 rejects invalid config" do
      assert {:error, {:validation, errors}} = MCPClient.add_server(%{})
      assert is_list(errors)
      assert match?([_ | _], errors)
    end

    test "add_server/1 rejects config missing required fields" do
      assert {:error, {:validation, errors}} =
               MCPClient.add_server(%{name: :test_only_name})

      assert Enum.any?(errors, &String.contains?(&1, "display_name"))
      assert Enum.any?(errors, &String.contains?(&1, "command"))
    end

    test "add_server/1 accepts valid config with enabled: false" do
      config = %{
        name: :test_add_disabled,
        display_name: "Test Disabled Server",
        command: "/usr/bin/false",
        args: [],
        enabled: false,
        requires_approval: false,
        dangerous_tools: [],
        description: "A test server that is disabled"
      }

      assert :ok = MCPClient.add_server(config)

      configs = MCPClient.list_server_configs()
      assert Enum.any?(configs, fn s -> s.name == :test_add_disabled end)

      # Clean up
      MCPClient.remove_server(:test_add_disabled)
    end

    test "add_server/1 rejects duplicate server name" do
      config = %{
        name: :test_duplicate,
        display_name: "Duplicate Test",
        command: "/usr/bin/false",
        enabled: false
      }

      assert :ok = MCPClient.add_server(config)
      assert {:error, msg} = MCPClient.add_server(config)
      assert msg =~ "already exists"

      # Clean up
      MCPClient.remove_server(:test_duplicate)
    end

    test "remove_server/1 removes a previously added server" do
      config = %{
        name: :test_remove,
        display_name: "Remove Test",
        command: "/usr/bin/false",
        enabled: false
      }

      assert :ok = MCPClient.add_server(config)
      assert Enum.any?(MCPClient.list_server_configs(), fn s -> s.name == :test_remove end)

      assert :ok = MCPClient.remove_server(:test_remove)
      refute Enum.any?(MCPClient.list_server_configs(), fn s -> s.name == :test_remove end)
    end

    test "remove_server/1 returns error for non-existent server" do
      assert {:error, msg} = MCPClient.remove_server(:nonexistent_server)
      assert msg =~ "not found"
    end

    test "update_server/2 updates an existing server's config" do
      config = %{
        name: :test_update,
        display_name: "Original Name",
        command: "/usr/bin/false",
        enabled: false,
        description: "original"
      }

      assert :ok = MCPClient.add_server(config)

      updated = %{
        name: :test_update,
        display_name: "Updated Name",
        command: "/usr/bin/true",
        enabled: false,
        description: "updated"
      }

      assert :ok = MCPClient.update_server(:test_update, updated)

      configs = MCPClient.list_server_configs()
      server = Enum.find(configs, fn s -> s.name == :test_update end)
      assert server.display_name == "Updated Name"
      assert server.description == "updated"

      # Clean up
      MCPClient.remove_server(:test_update)
    end

    test "update_server/2 returns error for non-existent server" do
      config = %{
        name: :nonexistent,
        display_name: "Nope",
        command: "/usr/bin/false"
      }

      assert {:error, msg} = MCPClient.update_server(:nonexistent, config)
      assert msg =~ "not found"
    end

    test "update_server/2 rejects invalid config" do
      config = %{
        name: :test_update_invalid,
        display_name: "Valid Server",
        command: "/usr/bin/false",
        enabled: false
      }

      assert :ok = MCPClient.add_server(config)

      assert {:error, {:validation, _errors}} =
               MCPClient.update_server(:test_update_invalid, %{name: :test_update_invalid})

      # Clean up
      MCPClient.remove_server(:test_update_invalid)
    end

    test "toggle_server/2 updates enabled state" do
      config = %{
        name: :test_toggle,
        display_name: "Toggle Test",
        command: "/usr/bin/false",
        enabled: false
      }

      assert :ok = MCPClient.add_server(config)

      server = Enum.find(MCPClient.list_server_configs(), fn s -> s.name == :test_toggle end)
      refute server.enabled

      # Toggle on — will try to start the server (which will fail since command is /usr/bin/false)
      # but the config should still be updated
      assert :ok = MCPClient.toggle_server(:test_toggle, true)

      server = Enum.find(MCPClient.list_server_configs(), fn s -> s.name == :test_toggle end)
      assert server.enabled

      # Toggle back off
      assert :ok = MCPClient.toggle_server(:test_toggle, false)

      server = Enum.find(MCPClient.list_server_configs(), fn s -> s.name == :test_toggle end)
      refute server.enabled

      # Clean up
      MCPClient.remove_server(:test_toggle)
    end

    test "toggle_server/2 returns error for non-existent server" do
      assert {:error, msg} = MCPClient.toggle_server(:nonexistent_toggle, true)
      assert msg =~ "not found"
    end

    test "add_server/1 persists config to file", %{config_path: config_path} do
      config = %{
        name: :test_persist,
        display_name: "Persist Test",
        command: "/usr/bin/false",
        enabled: false,
        description: "persistence test"
      }

      assert :ok = MCPClient.add_server(config)

      # Verify file was written
      assert File.exists?(config_path)
      {:ok, content} = File.read(config_path)
      {:ok, decoded} = Jason.decode(content)
      assert is_list(decoded["servers"])
      assert Enum.any?(decoded["servers"], fn s -> s["name"] == "test_persist" end)

      # Clean up
      MCPClient.remove_server(:test_persist)
    end

    test "remove_server/1 updates persisted config", %{config_path: config_path} do
      config = %{
        name: :test_persist_remove,
        display_name: "Persist Remove Test",
        command: "/usr/bin/false",
        enabled: false
      }

      assert :ok = MCPClient.add_server(config)
      assert :ok = MCPClient.remove_server(:test_persist_remove)

      {:ok, content} = File.read(config_path)
      {:ok, decoded} = Jason.decode(content)
      refute Enum.any?(decoded["servers"], fn s -> s["name"] == "test_persist_remove" end)
    end

    test "list_server_configs/0 returns all configs in order" do
      configs =
        for i <- 1..3 do
          %{
            name: :"test_order_#{i}",
            display_name: "Order Test #{i}",
            command: "/usr/bin/false",
            enabled: false
          }
        end

      for config <- configs, do: assert(:ok = MCPClient.add_server(config))

      result = MCPClient.list_server_configs()
      names = Enum.map(result, & &1.name)
      assert :test_order_1 in names
      assert :test_order_2 in names
      assert :test_order_3 in names

      # Clean up
      for config <- configs, do: MCPClient.remove_server(config.name)
    end

    test "remove_server/1 accepts string name" do
      config = %{
        name: :test_string_name,
        display_name: "String Name Test",
        command: "/usr/bin/false",
        enabled: false
      }

      assert :ok = MCPClient.add_server(config)
      assert :ok = MCPClient.remove_server("test_string_name")
      refute Enum.any?(MCPClient.list_server_configs(), fn s -> s.name == :test_string_name end)
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

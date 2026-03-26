defmodule OllamaChat.MCPConfigTest do
  use ExUnit.Case, async: false

  alias OllamaChat.MCPConfig

  @tmp_dir "tmp/test_mcp_config"

  setup do
    # Save original app env values
    original_config_path = Application.get_env(:ollama_chat, :mcp_config_path)
    original_mcp_servers = Application.get_env(:ollama_chat, :mcp_servers)

    # Create a unique temp directory for each test
    test_dir = Path.join(@tmp_dir, "#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    tmp_config_path = Path.join(test_dir, "mcp_servers.json")
    Application.put_env(:ollama_chat, :mcp_config_path, tmp_config_path)

    on_exit(fn ->
      # Restore original app env
      if original_config_path do
        Application.put_env(:ollama_chat, :mcp_config_path, original_config_path)
      else
        Application.delete_env(:ollama_chat, :mcp_config_path)
      end

      if original_mcp_servers do
        Application.put_env(:ollama_chat, :mcp_servers, original_mcp_servers)
      else
        Application.delete_env(:ollama_chat, :mcp_servers)
      end

      # Clean up temp directory
      File.rm_rf!(test_dir)
    end)

    %{test_dir: test_dir, tmp_config_path: tmp_config_path}
  end

  describe "config_path/0" do
    test "returns default path when no config set" do
      Application.delete_env(:ollama_chat, :mcp_config_path)

      path = MCPConfig.config_path()

      assert String.contains?(path, ".config/ollama_chat/mcp_servers.json")
      # Should be expanded (no tilde)
      refute String.contains?(path, "~")
    end

    test "returns configured path when app env is set" do
      Application.put_env(:ollama_chat, :mcp_config_path, "/custom/path/mcp.json")

      assert MCPConfig.config_path() == "/custom/path/mcp.json"
    end

    test "expands tilde in configured path" do
      Application.put_env(:ollama_chat, :mcp_config_path, "~/my_config/mcp.json")

      path = MCPConfig.config_path()

      refute String.starts_with?(path, "~")
      assert String.ends_with?(path, "my_config/mcp.json")
    end
  end

  describe "load/0" do
    test "returns {:ok, []} when file does not exist", %{tmp_config_path: tmp_config_path} do
      refute File.exists?(tmp_config_path)

      assert {:ok, []} = MCPConfig.load()
    end

    test "returns {:ok, servers} when valid JSON file exists", %{tmp_config_path: tmp_config_path} do
      servers_json = %{
        "servers" => [
          %{
            "name" => "mcp_filesystem",
            "display_name" => "MCP Filesystem",
            "description" => "File operations",
            "command" => "/usr/local/bin/mcp-fs",
            "args" => ["--root", "/tmp"],
            "enabled" => true,
            "requires_approval" => false,
            "dangerous_tools" => ["write_file"],
            "env" => %{}
          }
        ]
      }

      File.write!(tmp_config_path, Jason.encode!(servers_json))

      assert {:ok, [server]} = MCPConfig.load()
      assert server.name == :mcp_filesystem
      assert server.display_name == "MCP Filesystem"
      assert server.command == "/usr/local/bin/mcp-fs"
      assert server.args == ["--root", "/tmp"]
      assert server.enabled == true
    end

    test "returns {:error, _} when file contains invalid JSON", %{
      tmp_config_path: tmp_config_path
    } do
      File.write!(tmp_config_path, "{ this is not valid json !!!")

      assert {:error, _reason} = MCPConfig.load()
    end

    test "returns {:ok, []} when file contains empty servers list", %{
      tmp_config_path: tmp_config_path
    } do
      File.write!(tmp_config_path, Jason.encode!(%{"servers" => []}))

      assert {:ok, []} = MCPConfig.load()
    end

    test "loads multiple servers from JSON file", %{tmp_config_path: tmp_config_path} do
      servers_json = %{
        "servers" => [
          %{
            "name" => "mcp_filesystem",
            "display_name" => "MCP Filesystem",
            "command" => "/usr/bin/mcp-fs",
            "args" => [],
            "enabled" => true
          },
          %{
            "name" => "mcp_memory",
            "display_name" => "MCP Memory",
            "command" => "/usr/bin/mcp-mem",
            "args" => [],
            "enabled" => false
          }
        ]
      }

      File.write!(tmp_config_path, Jason.encode!(servers_json))

      assert {:ok, servers} = MCPConfig.load()
      assert length(servers) == 2
      assert Enum.map(servers, & &1.name) == [:mcp_filesystem, :mcp_memory]
    end
  end

  describe "save/1" do
    test "successfully writes config to file", %{tmp_config_path: tmp_config_path} do
      servers = [
        %{
          name: :mcp_filesystem,
          display_name: "MCP Filesystem",
          description: "File operations",
          command: "/usr/local/bin/mcp-fs",
          args: ["filesystem"],
          enabled: true,
          requires_approval: false,
          dangerous_tools: ["write_file"],
          env: %{}
        }
      ]

      assert :ok = MCPConfig.save(servers)

      # Verify file contents
      assert File.exists?(tmp_config_path)
      contents = File.read!(tmp_config_path)
      decoded = Jason.decode!(contents)

      assert is_list(decoded["servers"])
      assert length(decoded["servers"]) == 1

      [server] = decoded["servers"]
      assert server["name"] == "mcp_filesystem"
      assert server["display_name"] == "MCP Filesystem"
      assert server["command"] == "/usr/local/bin/mcp-fs"
      assert server["args"] == ["filesystem"]
      assert server["enabled"] == true
      assert server["dangerous_tools"] == ["write_file"]
    end

    test "creates parent directories if they don't exist", %{test_dir: test_dir} do
      nested_path = Path.join([test_dir, "deep", "nested", "dir", "mcp_servers.json"])
      Application.put_env(:ollama_chat, :mcp_config_path, nested_path)

      servers = [
        %{
          name: :test_server,
          display_name: "Test",
          command: "/usr/bin/test",
          args: [],
          enabled: true
        }
      ]

      assert :ok = MCPConfig.save(servers)
      assert File.exists?(nested_path)
    end

    test "written file is valid JSON", %{tmp_config_path: tmp_config_path} do
      servers = [
        %{
          name: :server_one,
          display_name: "Server One",
          description: "First server",
          command: "/bin/one",
          args: ["--flag"],
          enabled: true,
          requires_approval: true,
          dangerous_tools: [],
          env: %{"KEY" => "value"}
        },
        %{
          name: :server_two,
          display_name: "Server Two",
          command: "/bin/two",
          args: [],
          enabled: false
        }
      ]

      assert :ok = MCPConfig.save(servers)

      # File must be valid, parseable JSON
      contents = File.read!(tmp_config_path)
      assert {:ok, decoded} = Jason.decode(contents)
      assert is_map(decoded)
      assert is_list(decoded["servers"])
      assert length(decoded["servers"]) == 2
    end

    test "saves empty server list", %{tmp_config_path: tmp_config_path} do
      assert :ok = MCPConfig.save([])

      contents = File.read!(tmp_config_path)
      decoded = Jason.decode!(contents)
      assert decoded["servers"] == []
    end

    test "returns {:error, _} for invalid path" do
      # Use a path where a regular file acts as a directory component
      # to make directory creation fail
      blocker_file = Path.join(@tmp_dir, "blocker_file")
      File.write!(blocker_file, "I'm a file, not a directory")
      invalid_path = Path.join([blocker_file, "subdir", "mcp.json"])
      Application.put_env(:ollama_chat, :mcp_config_path, invalid_path)

      servers = [%{name: :test, display_name: "Test", command: "/bin/test", args: []}]

      assert {:error, _reason} = MCPConfig.save(servers)
    end
  end

  describe "validate_server_config/1" do
    test "valid config returns {:ok, normalized_config}" do
      config = %{
        name: :mcp_filesystem,
        display_name: "MCP Filesystem",
        command: "/usr/local/bin/mcp-fs"
      }

      assert {:ok, normalized} = MCPConfig.validate_server_config(config)

      # Required fields present
      assert normalized.name == :mcp_filesystem
      assert normalized.display_name == "MCP Filesystem"
      assert normalized.command == "/usr/local/bin/mcp-fs"

      # Defaults filled in
      assert is_list(normalized.args)
      assert is_boolean(normalized.enabled)
      assert is_boolean(normalized.requires_approval)
      assert is_list(normalized.dangerous_tools)
    end

    test "valid config with all fields returns {:ok, normalized_config}" do
      config = %{
        name: :mcp_filesystem,
        display_name: "MCP Filesystem",
        description: "File operations",
        command: "/usr/local/bin/mcp-fs",
        args: ["filesystem"],
        enabled: true,
        requires_approval: false,
        dangerous_tools: ["write_file"],
        env: %{"HOME" => "/tmp"}
      }

      assert {:ok, normalized} = MCPConfig.validate_server_config(config)
      assert normalized.name == :mcp_filesystem
      assert normalized.description == "File operations"
      assert normalized.args == ["filesystem"]
      assert normalized.dangerous_tools == ["write_file"]
      assert normalized.env == %{"HOME" => "/tmp"}
    end

    test "missing name returns error" do
      config = %{
        display_name: "MCP Filesystem",
        command: "/usr/local/bin/mcp-fs"
      }

      assert {:error, errors} = MCPConfig.validate_server_config(config)
      assert is_list(errors)
      assert Enum.any?(errors, fn e -> String.contains?(e, "name") end)
    end

    test "missing display_name returns error" do
      config = %{
        name: :mcp_filesystem,
        command: "/usr/local/bin/mcp-fs"
      }

      assert {:error, errors} = MCPConfig.validate_server_config(config)
      assert is_list(errors)
      assert Enum.any?(errors, fn e -> String.contains?(e, "display_name") end)
    end

    test "missing command returns error" do
      config = %{
        name: :mcp_filesystem,
        display_name: "MCP Filesystem"
      }

      assert {:error, errors} = MCPConfig.validate_server_config(config)
      assert is_list(errors)
      assert Enum.any?(errors, fn e -> String.contains?(e, "command") end)
    end

    test "empty name string returns error" do
      config = %{
        name: "",
        display_name: "MCP Filesystem",
        command: "/usr/local/bin/mcp-fs"
      }

      assert {:error, errors} = MCPConfig.validate_server_config(config)
      assert is_list(errors)
      assert Enum.any?(errors, fn e -> String.contains?(e, "name") end)
    end

    test "invalid types return error" do
      config = %{
        name: :mcp_filesystem,
        display_name: "MCP Filesystem",
        command: "/usr/local/bin/mcp-fs",
        args: "not a list"
      }

      assert {:error, errors} = MCPConfig.validate_server_config(config)
      assert is_list(errors)
      assert Enum.any?(errors, fn e -> String.contains?(e, "args") end)
    end

    test "string-keyed map is also accepted" do
      config = %{
        "name" => "mcp_filesystem",
        "display_name" => "MCP Filesystem",
        "command" => "/usr/local/bin/mcp-fs",
        "args" => ["filesystem"]
      }

      assert {:ok, normalized} = MCPConfig.validate_server_config(config)
      assert normalized.name == :mcp_filesystem
      assert normalized.display_name == "MCP Filesystem"
    end

    test "name is converted to atom in normalized output" do
      config = %{
        name: "my_server",
        display_name: "My Server",
        command: "/bin/my-server"
      }

      assert {:ok, normalized} = MCPConfig.validate_server_config(config)
      assert is_atom(normalized.name)
      assert normalized.name == :my_server
    end

    test "multiple missing required fields returns multiple errors" do
      config = %{}

      assert {:error, errors} = MCPConfig.validate_server_config(config)
      assert is_list(errors)
      assert length(errors) >= 3
    end
  end

  describe "to_internal/1 and to_json/1" do
    test "round-trips correctly: config |> to_json() |> to_internal() returns equivalent config" do
      original = %{
        name: :mcp_filesystem,
        display_name: "MCP Filesystem",
        description: "File operations",
        command: "/usr/local/bin/mcp-fs",
        args: ["filesystem"],
        enabled: true,
        requires_approval: false,
        dangerous_tools: ["write_file"],
        env: %{"HOME" => "/tmp"}
      }

      round_tripped = original |> MCPConfig.to_json() |> MCPConfig.to_internal()

      assert round_tripped.name == original.name
      assert round_tripped.display_name == original.display_name
      assert round_tripped.description == original.description
      assert round_tripped.command == original.command
      assert round_tripped.args == original.args
      assert round_tripped.enabled == original.enabled
      assert round_tripped.requires_approval == original.requires_approval
      assert round_tripped.dangerous_tools == original.dangerous_tools
      assert round_tripped.env == original.env
    end

    test "to_internal/1 converts string name to atom" do
      json_map = %{
        "name" => "mcp_filesystem",
        "display_name" => "MCP Filesystem",
        "command" => "/usr/local/bin/mcp-fs"
      }

      internal = MCPConfig.to_internal(json_map)

      assert internal.name == :mcp_filesystem
      assert is_atom(internal.name)
    end

    test "to_json/1 converts atom name to string" do
      internal_map = %{
        name: :mcp_filesystem,
        display_name: "MCP Filesystem",
        command: "/usr/local/bin/mcp-fs",
        args: [],
        enabled: true
      }

      json = MCPConfig.to_json(internal_map)

      assert json["name"] == "mcp_filesystem"
      assert is_binary(json["name"])
    end

    test "to_json/1 produces all string keys" do
      internal_map = %{
        name: :mcp_filesystem,
        display_name: "MCP Filesystem",
        description: "File operations",
        command: "/usr/local/bin/mcp-fs",
        args: ["filesystem"],
        enabled: true,
        requires_approval: false,
        dangerous_tools: ["write_file"],
        env: %{}
      }

      json = MCPConfig.to_json(internal_map)

      assert Enum.all?(Map.keys(json), &is_binary/1)
    end

    test "missing optional fields get defaults in to_internal/1" do
      json_map = %{
        "name" => "my_server",
        "display_name" => "My Server",
        "command" => "/bin/my-server"
      }

      internal = MCPConfig.to_internal(json_map)

      assert internal.name == :my_server
      assert internal.display_name == "My Server"
      assert internal.command == "/bin/my-server"
      # Optional fields should have defaults
      assert is_list(internal.args)
      assert is_boolean(internal.enabled)
      assert is_boolean(internal.requires_approval)
      assert is_list(internal.dangerous_tools)
    end

    test "to_internal/1 preserves all provided values" do
      json_map = %{
        "name" => "mcp_memory",
        "display_name" => "MCP Memory",
        "description" => "In-memory KV store",
        "command" => "/usr/bin/mcp-mem",
        "args" => ["--port", "3000"],
        "enabled" => false,
        "requires_approval" => true,
        "dangerous_tools" => ["delete_all"],
        "env" => %{"PORT" => "3000"}
      }

      internal = MCPConfig.to_internal(json_map)

      assert internal.name == :mcp_memory
      assert internal.description == "In-memory KV store"
      assert internal.args == ["--port", "3000"]
      assert internal.enabled == false
      assert internal.requires_approval == true
      assert internal.dangerous_tools == ["delete_all"]
      assert internal.env == %{"PORT" => "3000"}
    end
  end

  describe "load_with_defaults/0" do
    test "when no file exists, returns app config defaults" do
      app_servers = [
        %{
          name: :mcp_filesystem,
          display_name: "MCP Filesystem",
          command: "/usr/local/bin/mcp-fs",
          args: ["filesystem"],
          enabled: true,
          requires_approval: false,
          dangerous_tools: [],
          env: %{}
        }
      ]

      Application.put_env(:ollama_chat, :mcp_servers, app_servers)

      result = MCPConfig.load_with_defaults()

      assert is_list(result)
      assert length(result) == 1
      assert hd(result).name == :mcp_filesystem
    end

    test "when file has servers that override app defaults (same name), file wins", %{
      tmp_config_path: tmp_config_path
    } do
      # App config has server with enabled: true
      app_servers = [
        %{
          name: :mcp_filesystem,
          display_name: "MCP Filesystem (Default)",
          description: "Default description",
          command: "/usr/local/bin/mcp-fs-default",
          args: [],
          enabled: true,
          requires_approval: false,
          dangerous_tools: [],
          env: %{}
        }
      ]

      Application.put_env(:ollama_chat, :mcp_servers, app_servers)

      # File config overrides with enabled: false and different command
      file_json = %{
        "servers" => [
          %{
            "name" => "mcp_filesystem",
            "display_name" => "MCP Filesystem (Custom)",
            "description" => "Custom description",
            "command" => "/custom/bin/mcp-fs",
            "args" => ["--custom"],
            "enabled" => false,
            "requires_approval" => true,
            "dangerous_tools" => ["write_file"],
            "env" => %{}
          }
        ]
      }

      File.write!(tmp_config_path, Jason.encode!(file_json))

      result = MCPConfig.load_with_defaults()

      assert is_list(result)
      assert length(result) == 1

      server = hd(result)
      assert server.name == :mcp_filesystem
      # File config should win
      assert server.display_name == "MCP Filesystem (Custom)"
      assert server.command == "/custom/bin/mcp-fs"
      assert server.enabled == false
    end

    test "when file has extra servers not in app config, they're included", %{
      tmp_config_path: tmp_config_path
    } do
      app_servers = [
        %{
          name: :mcp_filesystem,
          display_name: "MCP Filesystem",
          command: "/usr/local/bin/mcp-fs",
          args: [],
          enabled: true,
          requires_approval: false,
          dangerous_tools: [],
          env: %{}
        }
      ]

      Application.put_env(:ollama_chat, :mcp_servers, app_servers)

      file_json = %{
        "servers" => [
          %{
            "name" => "mcp_custom",
            "display_name" => "Custom Server",
            "command" => "/usr/bin/custom-mcp",
            "args" => [],
            "enabled" => true,
            "requires_approval" => false,
            "dangerous_tools" => [],
            "env" => %{}
          }
        ]
      }

      File.write!(tmp_config_path, Jason.encode!(file_json))

      result = MCPConfig.load_with_defaults()

      names = Enum.map(result, & &1.name)
      assert :mcp_filesystem in names
      assert :mcp_custom in names
      assert length(result) == 2
    end

    test "when app config has servers not in file, they're included", %{
      tmp_config_path: tmp_config_path
    } do
      app_servers = [
        %{
          name: :mcp_filesystem,
          display_name: "MCP Filesystem",
          command: "/usr/local/bin/mcp-fs",
          args: [],
          enabled: true,
          requires_approval: false,
          dangerous_tools: [],
          env: %{}
        },
        %{
          name: :mcp_memory,
          display_name: "MCP Memory",
          command: "/usr/local/bin/mcp-mem",
          args: [],
          enabled: true,
          requires_approval: false,
          dangerous_tools: [],
          env: %{}
        }
      ]

      Application.put_env(:ollama_chat, :mcp_servers, app_servers)

      # File only has filesystem (overridden) — memory should still appear from app config
      file_json = %{
        "servers" => [
          %{
            "name" => "mcp_filesystem",
            "display_name" => "MCP Filesystem (File)",
            "command" => "/custom/mcp-fs",
            "args" => [],
            "enabled" => false,
            "requires_approval" => false,
            "dangerous_tools" => [],
            "env" => %{}
          }
        ]
      }

      File.write!(tmp_config_path, Jason.encode!(file_json))

      result = MCPConfig.load_with_defaults()

      names = Enum.map(result, & &1.name)
      assert :mcp_filesystem in names
      assert :mcp_memory in names
      assert length(result) == 2

      # File version of filesystem should win
      fs_server = Enum.find(result, &(&1.name == :mcp_filesystem))
      assert fs_server.display_name == "MCP Filesystem (File)"
      assert fs_server.enabled == false

      # Memory should come from app config unchanged
      mem_server = Enum.find(result, &(&1.name == :mcp_memory))
      assert mem_server.display_name == "MCP Memory"
      assert mem_server.enabled == true
    end

    test "returns empty list when no app config and no file" do
      Application.put_env(:ollama_chat, :mcp_servers, [])

      result = MCPConfig.load_with_defaults()

      assert result == []
    end
  end

  describe "save/1 and load/0 integration" do
    test "save then load round-trips server configs" do
      servers = [
        %{
          name: :mcp_filesystem,
          display_name: "MCP Filesystem",
          description: "File operations within the MCP workspace",
          command: "/usr/local/bin/mcp-fs",
          args: ["filesystem", "--root", "/tmp"],
          enabled: true,
          requires_approval: false,
          dangerous_tools: ["write_file", "delete_file"],
          env: %{"MCP_ROOT" => "/tmp"}
        },
        %{
          name: :mcp_memory,
          display_name: "MCP Memory",
          description: "In-memory key/value store",
          command: "/usr/local/bin/mcp-mem",
          args: ["memory"],
          enabled: false,
          requires_approval: true,
          dangerous_tools: [],
          env: %{}
        }
      ]

      assert :ok = MCPConfig.save(servers)
      assert {:ok, loaded} = MCPConfig.load()

      assert length(loaded) == 2

      fs = Enum.find(loaded, &(&1.name == :mcp_filesystem))
      assert fs.display_name == "MCP Filesystem"
      assert fs.description == "File operations within the MCP workspace"
      assert fs.command == "/usr/local/bin/mcp-fs"
      assert fs.args == ["filesystem", "--root", "/tmp"]
      assert fs.enabled == true
      assert fs.requires_approval == false
      assert fs.dangerous_tools == ["write_file", "delete_file"]

      mem = Enum.find(loaded, &(&1.name == :mcp_memory))
      assert mem.display_name == "MCP Memory"
      assert mem.enabled == false
      assert mem.requires_approval == true
    end
  end

  describe "parse_json_contents/1 edge cases (via load/0)" do
    test "empty file returns {:ok, []}", %{tmp_config_path: tmp_config_path} do
      File.write!(tmp_config_path, "")

      assert {:ok, []} = MCPConfig.load()
    end

    test "whitespace-only file returns {:ok, []}", %{tmp_config_path: tmp_config_path} do
      File.write!(tmp_config_path, "   \n\t\n  ")

      assert {:ok, []} = MCPConfig.load()
    end

    test "file with UTF-8 BOM prefix parses correctly", %{tmp_config_path: tmp_config_path} do
      json =
        Jason.encode!(%{
          "servers" => [
            %{
              "name" => "bom_server",
              "display_name" => "BOM Server",
              "command" => "/usr/bin/bom"
            }
          ]
        })

      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(tmp_config_path, bom <> json)

      assert {:ok, [server]} = MCPConfig.load()
      assert server.name == :bom_server
      assert server.display_name == "BOM Server"
      assert server.command == "/usr/bin/bom"
    end

    test "file with invalid JSON returns descriptive error", %{tmp_config_path: tmp_config_path} do
      File.write!(tmp_config_path, "{not json at all!!!")

      assert {:error, message} = MCPConfig.load()
      assert is_binary(message)
      assert message =~ "JSON parse error"
    end

    test "file with valid JSON but wrong structure returns error", %{
      tmp_config_path: tmp_config_path
    } do
      File.write!(tmp_config_path, Jason.encode!(%{"not_servers" => []}))

      assert {:error, message} = MCPConfig.load()
      assert message =~ "expected JSON object with a \"servers\" key"
    end
  end

  describe "validate_command_path/1" do
    test "empty command returns error" do
      assert {:error, "command is required"} = MCPConfig.validate_command_path("")
    end

    test "whitespace-only command returns error" do
      assert {:error, "command is required"} = MCPConfig.validate_command_path("   ")
    end

    test "absolute path to existing executable returns :ok" do
      # /usr/bin/env should exist and be executable on macOS/Linux
      assert :ok = MCPConfig.validate_command_path("/usr/bin/env")
    end

    test "absolute path to non-existent file returns warning" do
      assert {:warning, message} = MCPConfig.validate_command_path("/no/such/binary/here")
      assert message =~ "Command path does not exist"
      assert message =~ "/no/such/binary/here"
    end

    test "absolute path to non-executable file returns warning", %{test_dir: test_dir} do
      non_exec = test_dir |> Path.join("not_executable") |> Path.expand()
      File.write!(non_exec, "#!/bin/sh\necho hello")
      File.chmod!(non_exec, 0o644)

      assert {:warning, message} = MCPConfig.validate_command_path(non_exec)
      assert message =~ "Command path is not executable"
    end

    test "bare command that exists in PATH returns :ok" do
      # "env" should be available in PATH on any POSIX system
      assert :ok = MCPConfig.validate_command_path("env")
    end

    test "bare command not in PATH returns warning" do
      assert {:warning, message} =
               MCPConfig.validate_command_path("definitely_not_a_real_command_xyz")

      assert message =~ "not found in PATH"
      assert message =~ "definitely_not_a_real_command_xyz"
    end

    test "tilde path is expanded before checking", %{test_dir: _test_dir} do
      # A tilde path to something that doesn't exist should still expand and warn
      assert {:warning, message} = MCPConfig.validate_command_path("~/no_such_mcp_binary")
      assert message =~ "Command path does not exist"
      refute message =~ "~"
    end
  end
end

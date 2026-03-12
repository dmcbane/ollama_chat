defmodule McpTestServer.Server do
  @moduledoc """
  MCP server implementation using stdio transport.

  This server implements filesystem, memory, and utility tools
  compatible with the Model Context Protocol.
  """
  use GenServer

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    # Get workspace path
    workspace = Application.get_env(:mcp_test_server, :workspace_path, "/tmp/mcp_workspace")
    File.mkdir_p!(workspace)

    # Start stdio loop in a separate process
    spawn_link(fn -> stdio_loop() end)

    {:ok, %{workspace: workspace}}
  end

  # Stdio Loop

  defp stdio_loop do
    # Read from stdin
    case IO.read(:stdio, :line) do
      :eof ->
        System.halt(0)

      {:error, _reason} ->
        stdio_loop()

      line when is_binary(line) ->
        line = String.trim(line)

        if line != "" do
          handle_request(line)
        end

        stdio_loop()
    end
  end

  defp handle_request(line) do
    case Jason.decode(line) do
      {:ok, request} ->
        response = process_request(request)
        send_response(response)

      {:error, _reason} ->
        error_response = %{
          jsonrpc: "2.0",
          id: nil,
          error: %{
            code: -32700,
            message: "Parse error"
          }
        }

        send_response(error_response)
    end
  end

  defp process_request(%{"method" => "initialize", "id" => id, "params" => _params}) do
    # MCP protocol 2024-11-05 or newer
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        protocolVersion: "2024-11-05",
        serverInfo: %{
          name: "mcp-test-server",
          version: "0.3.0"
        },
        capabilities: %{
          tools: %{
            listChanged: true
          }
        }
      }
    }
  end

  # Fallback for initialize without params
  defp process_request(%{"method" => "initialize", "id" => id}) do
    process_request(%{"method" => "initialize", "id" => id, "params" => %{}})
  end

  defp process_request(%{"method" => "tools/list", "id" => id}) do
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        tools: list_tools()
      }
    }
  end

  defp process_request(%{"method" => "tools/call", "id" => id, "params" => params}) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    result = execute_tool(tool_name, arguments)

    %{
      jsonrpc: "2.0",
      id: id,
      result: result
    }
  end

  defp process_request(%{"method" => _method, "id" => id}) do
    %{
      jsonrpc: "2.0",
      id: id,
      error: %{
        code: -32601,
        message: "Method not found"
      }
    }
  end

  defp process_request(_request) do
    %{
      jsonrpc: "2.0",
      id: nil,
      error: %{
        code: -32600,
        message: "Invalid request"
      }
    }
  end

  defp send_response(response) do
    json = Jason.encode!(response)
    IO.puts(json)
  end

  # Tool Definitions

  defp list_tools do
    [
      # Filesystem tools
      %{
        name: "read_file",
        description: "Read the contents of a file from the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the file relative to workspace"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "write_file",
        description: "Write content to a file in the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the file relative to workspace"
            },
            content: %{
              type: "string",
              description: "Content to write to the file"
            }
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "list_directory",
        description: "List contents of a directory in the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the directory (use '.' for root)",
              default: "."
            }
          }
        }
      },
      %{
        name: "file_info",
        description: "Get information about a file or directory",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the file/directory"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "create_directory",
        description: "Create a new directory in the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the directory to create"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "move_file",
        description: "Move or rename a file or directory",
        inputSchema: %{
          type: "object",
          properties: %{
            source: %{
              type: "string",
              description: "Source path"
            },
            destination: %{
              type: "string",
              description: "Destination path"
            }
          },
          required: ["source", "destination"]
        }
      },
      %{
        name: "copy_file",
        description: "Copy a file to a new location",
        inputSchema: %{
          type: "object",
          properties: %{
            source: %{
              type: "string",
              description: "Source file path"
            },
            destination: %{
              type: "string",
              description: "Destination file path"
            }
          },
          required: ["source", "destination"]
        }
      },
      %{
        name: "delete_file",
        description: "Delete a file from the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the file to delete"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "delete_directory",
        description: "Delete a directory and all its contents",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the directory to delete"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "delete_files",
        description: "Delete multiple files at once (batch operation)",
        inputSchema: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "Array of file paths to delete"
            }
          },
          required: ["paths"]
        }
      },
      %{
        name: "delete_directories",
        description: "Delete multiple directories at once (batch operation)",
        inputSchema: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "Array of directory paths to delete"
            }
          },
          required: ["paths"]
        }
      },
      %{
        name: "delete_files_by_pattern",
        description: "Delete all files matching a glob pattern",
        inputSchema: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "Glob pattern (e.g., '*.tmp', 'logs/*.log', '**/*.bak')"
            },
            path: %{
              type: "string",
              description: "Directory to search in (default: workspace root)",
              default: "."
            }
          },
          required: ["pattern"]
        }
      },
      %{
        name: "delete_directories_by_pattern",
        description: "Delete all directories matching a name pattern",
        inputSchema: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "Name pattern (e.g., 'temp*', '*_backup', 'node_modules')"
            },
            path: %{
              type: "string",
              description: "Directory to search in (default: workspace root)",
              default: "."
            }
          },
          required: ["pattern"]
        }
      },
      %{
        name: "copy_files",
        description: "Copy multiple files at once (batch operation)",
        inputSchema: %{
          type: "object",
          properties: %{
            operations: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  source: %{type: "string"},
                  destination: %{type: "string"}
                },
                required: ["source", "destination"]
              },
              description: "Array of {source, destination} copy operations"
            }
          },
          required: ["operations"]
        }
      },
      %{
        name: "move_files",
        description: "Move multiple files at once (batch operation)",
        inputSchema: %{
          type: "object",
          properties: %{
            operations: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  source: %{type: "string"},
                  destination: %{type: "string"}
                },
                required: ["source", "destination"]
              },
              description: "Array of {source, destination} move operations"
            }
          },
          required: ["operations"]
        }
      },
      %{
        name: "search_files",
        description: "Search for files by name pattern",
        inputSchema: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "Search pattern (supports wildcards like *.txt)"
            },
            path: %{
              type: "string",
              description: "Directory to search in (default: workspace root)",
              default: "."
            }
          },
          required: ["pattern"]
        }
      },
      %{
        name: "get_file_size",
        description: "Get the size of a file in bytes",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the file"
            }
          },
          required: ["path"]
        }
      },
      # Memory tools
      %{
        name: "memory_set",
        description: "Store a value in memory with optional TTL",
        inputSchema: %{
          type: "object",
          properties: %{
            key: %{
              type: "string",
              description: "Key to store the value under"
            },
            value: %{
              type: "string",
              description: "Value to store"
            },
            ttl: %{
              type: "integer",
              description: "Time to live in seconds (optional)"
            }
          },
          required: ["key", "value"]
        }
      },
      %{
        name: "memory_get",
        description: "Retrieve a value from memory",
        inputSchema: %{
          type: "object",
          properties: %{
            key: %{
              type: "string",
              description: "Key to retrieve"
            }
          },
          required: ["key"]
        }
      },
      %{
        name: "memory_delete",
        description: "Delete a value from memory",
        inputSchema: %{
          type: "object",
          properties: %{
            key: %{
              type: "string",
              description: "Key to delete"
            }
          },
          required: ["key"]
        }
      },
      %{
        name: "memory_list",
        description: "List all keys in memory",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      },
      # Utility tools
      %{
        name: "echo",
        description: "Echo back the provided text",
        inputSchema: %{
          type: "object",
          properties: %{
            text: %{
              type: "string",
              description: "Text to echo back"
            }
          },
          required: ["text"]
        }
      },
      %{
        name: "get_time",
        description: "Get current server time",
        inputSchema: %{
          type: "object",
          properties: %{
            timezone: %{
              type: "string",
              description: "Timezone (default: UTC)",
              default: "UTC"
            }
          }
        }
      },
      %{
        name: "random_number",
        description: "Generate a random number within a range",
        inputSchema: %{
          type: "object",
          properties: %{
            min: %{
              type: "integer",
              description: "Minimum value",
              default: 1
            },
            max: %{
              type: "integer",
              description: "Maximum value",
              default: 100
            }
          }
        }
      },
      %{
        name: "hash_text",
        description: "Generate hash of provided text",
        inputSchema: %{
          type: "object",
          properties: %{
            text: %{
              type: "string",
              description: "Text to hash"
            },
            algorithm: %{
              type: "string",
              description: "Hash algorithm",
              default: "sha256",
              enum: ["md5", "sha256", "sha512"]
            }
          },
          required: ["text"]
        }
      },
      # Environment tools
      %{
        name: "list_env",
        description: "List all environment variables",
        inputSchema: %{
          type: "object",
          properties: %{
            filter: %{
              type: "string",
              description: "Optional filter pattern (case-insensitive substring match)"
            }
          }
        }
      },
      %{
        name: "get_env",
        description: "Get the value of a specific environment variable",
        inputSchema: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "Environment variable name"
            }
          },
          required: ["name"]
        }
      },
      # BEAM monitoring tools
      %{
        name: "beam_memory",
        description: "Get BEAM VM memory usage statistics",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "beam_processes",
        description: "List information about BEAM processes",
        inputSchema: %{
          type: "object",
          properties: %{
            limit: %{
              type: "integer",
              description: "Maximum number of processes to return",
              default: 20
            },
            sort_by: %{
              type: "string",
              description: "Sort processes by: memory, reductions, message_queue",
              default: "memory",
              enum: ["memory", "reductions", "message_queue"]
            }
          }
        }
      },
      %{
        name: "beam_system_info",
        description: "Get BEAM VM system information",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "beam_schedulers",
        description: "Get BEAM scheduler information",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "beam_applications",
        description: "List loaded OTP applications",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "beam_ets_tables",
        description: "List ETS (Erlang Term Storage) tables",
        inputSchema: %{
          type: "object",
          properties: %{
            limit: %{
              type: "integer",
              description: "Maximum number of tables to return",
              default: 20
            }
          }
        }
      }
    ]
  end

  # Tool Execution

  defp execute_tool(tool_name, arguments) do
    case tool_name do
      "read_file" -> handle_read_file(arguments)
      "write_file" -> handle_write_file(arguments)
      "list_directory" -> handle_list_directory(arguments)
      "file_info" -> handle_file_info(arguments)
      "create_directory" -> handle_create_directory(arguments)
      "move_file" -> handle_move_file(arguments)
      "copy_file" -> handle_copy_file(arguments)
      "delete_file" -> handle_delete_file(arguments)
      "delete_directory" -> handle_delete_directory(arguments)
      "search_files" -> handle_search_files(arguments)
      "get_file_size" -> handle_get_file_size(arguments)
      "memory_set" -> handle_memory_set(arguments)
      "memory_get" -> handle_memory_get(arguments)
      "memory_delete" -> handle_memory_delete(arguments)
      "memory_list" -> handle_memory_list(arguments)
      "echo" -> handle_echo(arguments)
      "get_time" -> handle_get_time(arguments)
      "random_number" -> handle_random_number(arguments)
      "hash_text" -> handle_hash_text(arguments)
      "list_env" -> handle_list_env(arguments)
      "get_env" -> handle_get_env(arguments)
      "beam_memory" -> handle_beam_memory(arguments)
      "beam_processes" -> handle_beam_processes(arguments)
      "beam_system_info" -> handle_beam_system_info(arguments)
      "beam_schedulers" -> handle_beam_schedulers(arguments)
      "beam_applications" -> handle_beam_applications(arguments)
      "beam_ets_tables" -> handle_beam_ets_tables(arguments)
      "delete_files" -> handle_delete_files(arguments)
      "delete_directories" -> handle_delete_directories(arguments)
      "delete_files_by_pattern" -> handle_delete_files_by_pattern(arguments)
      "delete_directories_by_pattern" -> handle_delete_directories_by_pattern(arguments)
      "copy_files" -> handle_copy_files(arguments)
      "move_files" -> handle_move_files(arguments)
      _ -> %{isError: true, content: [%{type: "text", text: "Unknown tool: #{tool_name}"}]}
    end
  end

  # Tool Handlers - Filesystem

  defp handle_read_file(%{"path" => path}) do
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        case File.read(full_path) do
          {:ok, content} ->
            %{
              content: [
                %{
                  type: "text",
                  text: "File: #{path}\n\n#{content}"
                }
              ]
            }

          {:error, :enoent} ->
            %{isError: true, content: [%{type: "text", text: "File not found: #{path}"}]}

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error reading file: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_write_file(%{"path" => path, "content" => content}) do
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        full_path |> Path.dirname() |> File.mkdir_p!()

        case File.write(full_path, content) do
          :ok ->
            %{
              content: [
                %{
                  type: "text",
                  text: "Successfully wrote #{byte_size(content)} bytes to #{path}"
                }
              ]
            }

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error writing file: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_list_directory(args) do
    path = Map.get(args, "path", ".")
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        case File.ls(full_path) do
          {:ok, entries} ->
            entries_text =
              entries
              |> Enum.map(fn entry ->
                entry_path = Path.join(full_path, entry)

                case File.stat(entry_path) do
                  {:ok, stat} ->
                    type = if stat.type == :directory, do: "📁", else: "📄"
                    size = format_size(stat.size)
                    "#{type} #{entry} (#{size})"

                  _ ->
                    "❓ #{entry}"
                end
              end)
              |> Enum.sort()
              |> Enum.join("\n")

            %{
              content: [
                %{
                  type: "text",
                  text: "Directory: #{path}\n\n#{entries_text}"
                }
              ]
            }

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error listing directory: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_file_info(%{"path" => path}) do
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        case File.stat(full_path) do
          {:ok, stat} ->
            info = """
            File Information: #{path}

            Type: #{stat.type}
            Size: #{format_size(stat.size)} (#{stat.size} bytes)
            Access: #{stat.access}
            Modified: #{format_datetime(stat.mtime)}
            """

            %{
              content: [
                %{
                  type: "text",
                  text: info
                }
              ]
            }

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error getting file info: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  # Tool Handlers - Additional Filesystem Operations

  defp handle_create_directory(%{"path" => path}) do
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        case File.mkdir_p(full_path) do
          :ok ->
            %{
              content: [
                %{
                  type: "text",
                  text: "Created directory: #{path}"
                }
              ]
            }

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error creating directory: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_move_file(%{"source" => source, "destination" => destination}) do
    workspace = get_workspace()
    source_path = Path.join(workspace, source)
    dest_path = Path.join(workspace, destination)

    with :ok <- validate_path(source_path, workspace),
         :ok <- validate_path(dest_path, workspace) do
      # Ensure destination directory exists
      dest_path |> Path.dirname() |> File.mkdir_p!()

      case File.rename(source_path, dest_path) do
        :ok ->
          %{
            content: [
              %{
                type: "text",
                text: "Moved: #{source} -> #{destination}"
              }
            ]
          }

        {:error, reason} ->
          %{
            isError: true,
            content: [%{type: "text", text: "Error moving file: #{inspect(reason)}"}]
          }
      end
    else
      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_copy_file(%{"source" => source, "destination" => destination}) do
    workspace = get_workspace()
    source_path = Path.join(workspace, source)
    dest_path = Path.join(workspace, destination)

    with :ok <- validate_path(source_path, workspace),
         :ok <- validate_path(dest_path, workspace) do
      # Ensure destination directory exists
      dest_path |> Path.dirname() |> File.mkdir_p!()

      case File.cp(source_path, dest_path) do
        :ok ->
          %{
            content: [
              %{
                type: "text",
                text: "Copied: #{source} -> #{destination}"
              }
            ]
          }

        {:error, reason} ->
          %{
            isError: true,
            content: [%{type: "text", text: "Error copying file: #{inspect(reason)}"}]
          }
      end
    else
      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_delete_file(%{"path" => path}) do
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        case File.rm(full_path) do
          :ok ->
            %{
              content: [
                %{
                  type: "text",
                  text: "Deleted file: #{path}"
                }
              ]
            }

          {:error, :enoent} ->
            %{isError: true, content: [%{type: "text", text: "File not found: #{path}"}]}

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error deleting file: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_delete_directory(%{"path" => path}) do
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        case File.rm_rf(full_path) do
          {:ok, _files} ->
            %{
              content: [
                %{
                  type: "text",
                  text: "Deleted directory: #{path}"
                }
              ]
            }

          {:error, reason, _file} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error deleting directory: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  # Batch delete operations
  defp handle_delete_files(%{"paths" => paths}) when is_list(paths) do
    workspace = get_workspace()

    results = Enum.map(paths, fn path ->
      full_path = Path.join(workspace, path)

      case validate_path(full_path, workspace) do
        :ok ->
          case File.rm(full_path) do
            :ok -> {:ok, path}
            {:error, :enoent} -> {:error, path, "not found"}
            {:error, reason} -> {:error, path, inspect(reason)}
          end
        {:error, reason} ->
          {:error, path, reason}
      end
    end)

    successful = Enum.filter(results, fn
      {:ok, _} -> true
      _ -> false
    end)

    failed = Enum.filter(results, fn
      {:error, _, _} -> true
      _ -> false
    end)

    success_count = length(successful)
    fail_count = length(failed)

    text = cond do
      fail_count == 0 ->
        "Successfully deleted #{success_count} file(s)"
      success_count == 0 ->
        error_details = Enum.map(failed, fn {:error, path, reason} ->
          "  - #{path}: #{reason}"
        end) |> Enum.join("\n")
        "Failed to delete all files:\n#{error_details}"
      true ->
        success_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
        error_list = Enum.map(failed, fn {:error, path, reason} -> "  ✗ #{path}: #{reason}" end) |> Enum.join("\n")
        "Deleted #{success_count} file(s), #{fail_count} failed:\nSuccessful:\n#{success_list}\nFailed:\n#{error_list}"
    end

    if fail_count > 0 and success_count == 0 do
      %{isError: true, content: [%{type: "text", text: text}]}
    else
      %{content: [%{type: "text", text: text}]}
    end
  end

  defp handle_delete_directories(%{"paths" => paths}) when is_list(paths) do
    workspace = get_workspace()

    results = Enum.map(paths, fn path ->
      full_path = Path.join(workspace, path)

      case validate_path(full_path, workspace) do
        :ok ->
          case File.rm_rf(full_path) do
            {:ok, _files} -> {:ok, path}
            {:error, reason, _file} -> {:error, path, inspect(reason)}
          end
        {:error, reason} ->
          {:error, path, reason}
      end
    end)

    successful = Enum.filter(results, fn
      {:ok, _} -> true
      _ -> false
    end)

    failed = Enum.filter(results, fn
      {:error, _, _} -> true
      _ -> false
    end)

    success_count = length(successful)
    fail_count = length(failed)

    text = cond do
      fail_count == 0 ->
        "Successfully deleted #{success_count} director#{if success_count == 1, do: "y", else: "ies"}"
      success_count == 0 ->
        error_details = Enum.map(failed, fn {:error, path, reason} ->
          "  - #{path}: #{reason}"
        end) |> Enum.join("\n")
        "Failed to delete all directories:\n#{error_details}"
      true ->
        success_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
        error_list = Enum.map(failed, fn {:error, path, reason} -> "  ✗ #{path}: #{reason}" end) |> Enum.join("\n")
        "Deleted #{success_count} director#{if success_count == 1, do: "y", else: "ies"}, #{fail_count} failed:\nSuccessful:\n#{success_list}\nFailed:\n#{error_list}"
    end

    if fail_count > 0 and success_count == 0 do
      %{isError: true, content: [%{type: "text", text: text}]}
    else
      %{content: [%{type: "text", text: text}]}
    end
  end

  defp handle_delete_files_by_pattern(%{"pattern" => pattern} = args) do
    workspace = get_workspace()
    search_path = Map.get(args, "path", ".")
    full_search_path = Path.join(workspace, search_path)

    case validate_path(full_search_path, workspace) do
      :ok ->
        # Find all files matching the pattern
        full_pattern = Path.join(full_search_path, pattern)
        matches = Path.wildcard(full_pattern)

        # Filter to only files (not directories)
        files = Enum.filter(matches, fn path ->
          File.regular?(path)
        end)

        if Enum.empty?(files) do
          %{content: [%{type: "text", text: "No files found matching pattern: #{pattern}"}]}
        else
          # Delete all matching files
          results = Enum.map(files, fn full_path ->
            relative_path = Path.relative_to(full_path, workspace)
            case File.rm(full_path) do
              :ok -> {:ok, relative_path}
              {:error, reason} -> {:error, relative_path, inspect(reason)}
            end
          end)

          successful = Enum.filter(results, fn {:ok, _} -> true; _ -> false end)
          failed = Enum.filter(results, fn {:error, _, _} -> true; _ -> false end)

          success_count = length(successful)
          fail_count = length(failed)

          text = cond do
            fail_count == 0 ->
              file_list = Enum.map(successful, fn {:ok, path} -> "  - #{path}" end) |> Enum.join("\n")
              "Deleted #{success_count} file(s) matching '#{pattern}':\n#{file_list}"
            success_count == 0 ->
              error_details = Enum.map(failed, fn {:error, path, reason} ->
                "  - #{path}: #{reason}"
              end) |> Enum.join("\n")
              "Failed to delete files:\n#{error_details}"
            true ->
              success_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
              error_list = Enum.map(failed, fn {:error, path, reason} -> "  ✗ #{path}: #{reason}" end) |> Enum.join("\n")
              "Deleted #{success_count} file(s), #{fail_count} failed:\nSuccessful:\n#{success_list}\nFailed:\n#{error_list}"
          end

          if fail_count > 0 and success_count == 0 do
            %{isError: true, content: [%{type: "text", text: text}]}
          else
            %{content: [%{type: "text", text: text}]}
          end
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_delete_directories_by_pattern(%{"pattern" => pattern} = args) do
    workspace = get_workspace()
    search_path = Map.get(args, "path", ".")
    full_search_path = Path.join(workspace, search_path)

    case validate_path(full_search_path, workspace) do
      :ok ->
        # Find all items in the search path
        case File.ls(full_search_path) do
          {:ok, entries} ->
            # Filter directories that match the pattern
            matching_dirs = Enum.filter(entries, fn entry ->
              full_entry_path = Path.join(full_search_path, entry)
              File.dir?(full_entry_path) and String.match?(entry, pattern_to_regex(pattern))
            end)

            if Enum.empty?(matching_dirs) do
              %{content: [%{type: "text", text: "No directories found matching pattern: #{pattern}"}]}
            else
              # Delete all matching directories
              results = Enum.map(matching_dirs, fn dir ->
                full_path = Path.join(full_search_path, dir)
                relative_path = Path.relative_to(full_path, workspace)

                case File.rm_rf(full_path) do
                  {:ok, _files} -> {:ok, relative_path}
                  {:error, reason, _file} -> {:error, relative_path, inspect(reason)}
                end
              end)

              successful = Enum.filter(results, fn {:ok, _} -> true; _ -> false end)
              failed = Enum.filter(results, fn {:error, _, _} -> true; _ -> false end)

              success_count = length(successful)
              fail_count = length(failed)

              text = cond do
                fail_count == 0 ->
                  dir_list = Enum.map(successful, fn {:ok, path} -> "  - #{path}" end) |> Enum.join("\n")
                  "Deleted #{success_count} director#{if success_count == 1, do: "y", else: "ies"} matching '#{pattern}':\n#{dir_list}"
                success_count == 0 ->
                  error_details = Enum.map(failed, fn {:error, path, reason} ->
                    "  - #{path}: #{reason}"
                  end) |> Enum.join("\n")
                  "Failed to delete directories:\n#{error_details}"
                true ->
                  success_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
                  error_list = Enum.map(failed, fn {:error, path, reason} -> "  ✗ #{path}: #{reason}" end) |> Enum.join("\n")
                  "Deleted #{success_count} director#{if success_count == 1, do: "y", else: "ies"}, #{fail_count} failed:\nSuccessful:\n#{success_list}\nFailed:\n#{error_list}"
              end

              if fail_count > 0 and success_count == 0 do
                %{isError: true, content: [%{type: "text", text: text}]}
              else
                %{content: [%{type: "text", text: text}]}
              end
            end

          {:error, reason} ->
            %{isError: true, content: [%{type: "text", text: "Error reading directory: #{inspect(reason)}"}]}
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  # Helper function to convert simple wildcard pattern to regex
  defp pattern_to_regex(pattern) do
    # Escape regex special characters except * and ?
    escaped = Regex.escape(pattern)
    # Convert * to .* and ? to .
    regex_pattern = escaped
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    ~r/^#{regex_pattern}$/
  end

  # Batch copy and move operations
  defp handle_copy_files(%{"operations" => operations}) when is_list(operations) do
    workspace = get_workspace()

    results = Enum.map(operations, fn operation ->
      source = Map.get(operation, "source")
      destination = Map.get(operation, "destination")

      if is_nil(source) or is_nil(destination) do
        {:error, "#{source} → #{destination}", "missing source or destination"}
      else
        source_full = Path.join(workspace, source)
        dest_full = Path.join(workspace, destination)

        with :ok <- validate_path(source_full, workspace),
             :ok <- validate_path(dest_full, workspace) do
          case File.copy(source_full, dest_full) do
            {:ok, _bytes} -> {:ok, "#{source} → #{destination}"}
            {:error, reason} -> {:error, "#{source} → #{destination}", inspect(reason)}
          end
        else
          {:error, reason} -> {:error, "#{source} → #{destination}", reason}
        end
      end
    end)

    successful = Enum.filter(results, fn {:ok, _} -> true; _ -> false end)
    failed = Enum.filter(results, fn {:error, _, _} -> true; _ -> false end)

    success_count = length(successful)
    fail_count = length(failed)

    text = cond do
      fail_count == 0 ->
        file_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
        "Successfully copied #{success_count} file(s):\n#{file_list}"
      success_count == 0 ->
        error_details = Enum.map(failed, fn {:error, path, reason} ->
          "  ✗ #{path}: #{reason}"
        end) |> Enum.join("\n")
        "Failed to copy all files:\n#{error_details}"
      true ->
        success_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
        error_list = Enum.map(failed, fn {:error, path, reason} -> "  ✗ #{path}: #{reason}" end) |> Enum.join("\n")
        "Copied #{success_count} file(s), #{fail_count} failed:\nSuccessful:\n#{success_list}\nFailed:\n#{error_list}"
    end

    if fail_count > 0 and success_count == 0 do
      %{isError: true, content: [%{type: "text", text: text}]}
    else
      %{content: [%{type: "text", text: text}]}
    end
  end

  defp handle_move_files(%{"operations" => operations}) when is_list(operations) do
    workspace = get_workspace()

    results = Enum.map(operations, fn operation ->
      source = Map.get(operation, "source")
      destination = Map.get(operation, "destination")

      if is_nil(source) or is_nil(destination) do
        {:error, "#{source} → #{destination}", "missing source or destination"}
      else
        source_full = Path.join(workspace, source)
        dest_full = Path.join(workspace, destination)

        with :ok <- validate_path(source_full, workspace),
             :ok <- validate_path(dest_full, workspace) do
          case File.rename(source_full, dest_full) do
            :ok -> {:ok, "#{source} → #{destination}"}
            {:error, reason} -> {:error, "#{source} → #{destination}", inspect(reason)}
          end
        else
          {:error, reason} -> {:error, "#{source} → #{destination}", reason}
        end
      end
    end)

    successful = Enum.filter(results, fn {:ok, _} -> true; _ -> false end)
    failed = Enum.filter(results, fn {:error, _, _} -> true; _ -> false end)

    success_count = length(successful)
    fail_count = length(failed)

    text = cond do
      fail_count == 0 ->
        file_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
        "Successfully moved #{success_count} file(s):\n#{file_list}"
      success_count == 0 ->
        error_details = Enum.map(failed, fn {:error, path, reason} ->
          "  ✗ #{path}: #{reason}"
        end) |> Enum.join("\n")
        "Failed to move all files:\n#{error_details}"
      true ->
        success_list = Enum.map(successful, fn {:ok, path} -> "  ✓ #{path}" end) |> Enum.join("\n")
        error_list = Enum.map(failed, fn {:error, path, reason} -> "  ✗ #{path}: #{reason}" end) |> Enum.join("\n")
        "Moved #{success_count} file(s), #{fail_count} failed:\nSuccessful:\n#{success_list}\nFailed:\n#{error_list}"
    end

    if fail_count > 0 and success_count == 0 do
      %{isError: true, content: [%{type: "text", text: text}]}
    else
      %{content: [%{type: "text", text: text}]}
    end
  end

  defp handle_search_files(%{"pattern" => pattern} = args) do
    workspace = get_workspace()
    search_path = Map.get(args, "path", ".")
    full_path = Path.join(workspace, search_path)

    case validate_path(full_path, workspace) do
      :ok ->
        # Convert wildcard pattern to regex
        regex_pattern =
          pattern
          |> String.replace(".", "\\.")
          |> String.replace("*", ".*")
          |> String.replace("?", ".")
          |> then(&("^" <> &1 <> "$"))

        case Regex.compile(regex_pattern) do
          {:ok, regex} ->
            matches =
              full_path
              |> Path.join("**/*")
              |> Path.wildcard()
              |> Enum.filter(fn path ->
                File.regular?(path) && Regex.match?(regex, Path.basename(path))
              end)
              |> Enum.map(fn path ->
                Path.relative_to(path, workspace)
              end)

            result_text =
              if Enum.empty?(matches) do
                "No files found matching pattern: #{pattern}"
              else
                "Found #{length(matches)} file(s):\n" <> Enum.join(matches, "\n")
              end

            %{
              content: [
                %{
                  type: "text",
                  text: result_text
                }
              ]
            }

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Invalid pattern: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_get_file_size(%{"path" => path}) do
    workspace = get_workspace()
    full_path = Path.join(workspace, path)

    case validate_path(full_path, workspace) do
      :ok ->
        case File.stat(full_path) do
          {:ok, %{size: size, type: :regular}} ->
            %{
              content: [
                %{
                  type: "text",
                  text: "File: #{path}\nSize: #{format_size(size)} (#{size} bytes)"
                }
              ]
            }

          {:ok, %{type: :directory}} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Path is a directory, not a file: #{path}"}]
            }

          {:error, :enoent} ->
            %{isError: true, content: [%{type: "text", text: "File not found: #{path}"}]}

          {:error, reason} ->
            %{
              isError: true,
              content: [%{type: "text", text: "Error getting file size: #{inspect(reason)}"}]
            }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  # Tool Handlers - Memory

  defp handle_memory_set(%{"key" => key, "value" => value} = args) do
    ttl = Map.get(args, "ttl")

    case McpTestServer.MemoryStore.set(key, value, ttl) do
      :ok ->
        ttl_info = if ttl, do: " (TTL: #{ttl}s)", else: ""

        %{
          content: [
            %{
              type: "text",
              text: "Stored value for key '#{key}'#{ttl_info}"
            }
          ]
        }

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end

  defp handle_memory_get(%{"key" => key}) do
    case McpTestServer.MemoryStore.get(key) do
      {:ok, value} ->
        %{
          content: [
            %{
              type: "text",
              text: "Value for key '#{key}':\n#{value}"
            }
          ]
        }

      {:error, :not_found} ->
        %{isError: true, content: [%{type: "text", text: "Key not found: #{key}"}]}

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end

  defp handle_memory_delete(%{"key" => key}) do
    case McpTestServer.MemoryStore.delete(key) do
      :ok ->
        %{
          content: [
            %{
              type: "text",
              text: "Deleted key '#{key}'"
            }
          ]
        }

      {:error, :not_found} ->
        %{isError: true, content: [%{type: "text", text: "Key not found: #{key}"}]}

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end

  defp handle_memory_list(_args) do
    case McpTestServer.MemoryStore.list_keys() do
      {:ok, keys} ->
        if Enum.empty?(keys) do
          %{
            content: [
              %{
                type: "text",
                text: "No keys stored in memory"
              }
            ]
          }
        else
          keys_text = keys |> Enum.sort() |> Enum.join("\n")

          %{
            content: [
              %{
                type: "text",
                text: "Stored keys (#{length(keys)}):\n#{keys_text}"
              }
            ]
          }
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end

  # Tool Handlers - Utility

  defp handle_echo(%{"text" => text}) do
    %{
      content: [
        %{
          type: "text",
          text: text
        }
      ]
    }
  end

  defp handle_get_time(args) do
    timezone = Map.get(args, "timezone", "UTC")
    now = DateTime.utc_now()

    time_info = """
    Current Time (#{timezone}):
    #{DateTime.to_string(now)}

    Unix timestamp: #{DateTime.to_unix(now)}
    ISO 8601: #{DateTime.to_iso8601(now)}
    """

    %{
      content: [
        %{
          type: "text",
          text: time_info
        }
      ]
    }
  end

  defp handle_random_number(args) do
    min = Map.get(args, "min", 1)
    max = Map.get(args, "max", 100)

    if min > max do
      %{isError: true, content: [%{type: "text", text: "min must be <= max"}]}
    else
      number = Enum.random(min..max)

      %{
        content: [
          %{
            type: "text",
            text: "Random number between #{min} and #{max}: #{number}"
          }
        ]
      }
    end
  end

  defp handle_hash_text(%{"text" => text} = args) do
    algorithm = Map.get(args, "algorithm", "sha256")

    hash =
      case algorithm do
        "md5" -> :crypto.hash(:md5, text) |> Base.encode16(case: :lower)
        "sha256" -> :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
        "sha512" -> :crypto.hash(:sha512, text) |> Base.encode16(case: :lower)
        _ -> nil
      end

    if hash do
      %{
        content: [
          %{
            type: "text",
            text: "#{String.upcase(algorithm)} hash:\n#{hash}"
          }
        ]
      }
    else
      %{isError: true, content: [%{type: "text", text: "Unsupported algorithm: #{algorithm}"}]}
    end
  end

  # Helper Functions

  defp get_workspace do
    Application.get_env(:mcp_test_server, :workspace_path, "/tmp/mcp_workspace")
  end

  defp validate_path(full_path, workspace) do
    real_path = Path.expand(full_path)
    real_workspace = Path.expand(workspace)

    if String.starts_with?(real_path, real_workspace) do
      :ok
    else
      {:error, "Access denied: path outside workspace"}
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)}KB"

  defp format_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 2)}MB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 2)}GB"

  defp format_datetime({{year, month, day}, {hour, minute, second}}) do
    "#{year}-#{pad(month)}-#{pad(day)} #{pad(hour)}:#{pad(minute)}:#{pad(second)}"
  end

  defp pad(num) when num < 10, do: "0#{num}"
  defp pad(num), do: "#{num}"

  # Tool Handlers - Environment Variables

  defp handle_list_env(args) do
    filter = Map.get(args, "filter")

    env_vars =
      System.get_env()
      |> Enum.filter(fn {key, _value} ->
        if filter do
          String.contains?(String.downcase(key), String.downcase(filter))
        else
          true
        end
      end)
      |> Enum.sort()

    result_text =
      if Enum.empty?(env_vars) do
        if filter do
          "No environment variables matching filter: #{filter}"
        else
          "No environment variables found"
        end
      else
        count = length(env_vars)
        header = if filter, do: "Environment variables matching '#{filter}' (#{count}):", else: "Environment variables (#{count}):"

        vars_text =
          env_vars
          |> Enum.map(fn {key, value} ->
            # Truncate long values
            display_value = if String.length(value) > 100, do: String.slice(value, 0, 97) <> "...", else: value
            "#{key}=#{display_value}"
          end)
          |> Enum.join("\n")

        "#{header}\n\n#{vars_text}"
      end

    %{
      content: [
        %{
          type: "text",
          text: result_text
        }
      ]
    }
  end

  defp handle_get_env(%{"name" => name}) do
    case System.get_env(name) do
      nil ->
        %{
          isError: true,
          content: [%{type: "text", text: "Environment variable not found: #{name}"}]
        }

      value ->
        %{
          content: [
            %{
              type: "text",
              text: "#{name}=#{value}"
            }
          ]
        }
    end
  end

  # Tool Handlers - BEAM Monitoring

  defp handle_beam_memory(_args) do
    memory = :erlang.memory()

    total_mb = Float.round(memory[:total] / 1_048_576, 2)
    processes_mb = Float.round(memory[:processes] / 1_048_576, 2)
    processes_used_mb = Float.round(memory[:processes_used] / 1_048_576, 2)
    system_mb = Float.round(memory[:system] / 1_048_576, 2)
    atom_mb = Float.round(memory[:atom] / 1_048_576, 2)
    binary_mb = Float.round(memory[:binary] / 1_048_576, 2)
    code_mb = Float.round(memory[:code] / 1_048_576, 2)
    ets_mb = Float.round(memory[:ets] / 1_048_576, 2)

    result_text = """
    BEAM VM Memory Usage:

    Total:            #{total_mb} MB
    Processes:        #{processes_mb} MB (used: #{processes_used_mb} MB)
    System:           #{system_mb} MB
    Atoms:            #{atom_mb} MB
    Binaries:         #{binary_mb} MB
    Code:             #{code_mb} MB
    ETS:              #{ets_mb} MB

    Raw bytes:
    Total:            #{memory[:total]} bytes
    Processes:        #{memory[:processes]} bytes
    System:           #{memory[:system]} bytes
    """

    %{
      content: [
        %{
          type: "text",
          text: result_text
        }
      ]
    }
  end

  defp handle_beam_processes(args) do
    limit = Map.get(args, "limit", 20)
    sort_by = Map.get(args, "sort_by", "memory")

    processes =
      Process.list()
      |> Enum.map(fn pid ->
        info = Process.info(pid, [:memory, :reductions, :message_queue_len, :registered_name, :current_function])

        case info do
          nil -> nil
          data ->
            %{
              pid: inspect(pid),
              memory: data[:memory] || 0,
              reductions: data[:reductions] || 0,
              message_queue: data[:message_queue_len] || 0,
              name: data[:registered_name] || :unnamed,
              current_function: format_function(data[:current_function])
            }
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> then(fn procs ->
        case sort_by do
          "memory" -> Enum.sort_by(procs, & &1.memory, :desc)
          "reductions" -> Enum.sort_by(procs, & &1.reductions, :desc)
          "message_queue" -> Enum.sort_by(procs, & &1.message_queue, :desc)
          _ -> procs
        end
      end)
      |> Enum.take(limit)

    result_text =
      if Enum.empty?(processes) do
        "No processes found"
      else
        header = "Top #{length(processes)} processes (sorted by #{sort_by}):\n\n"

        procs_text =
          processes
          |> Enum.map(fn proc ->
            mem_kb = Float.round(proc.memory / 1024, 2)
            name_str = if proc.name == :unnamed, do: "", else: " (#{proc.name})"
            "PID: #{proc.pid}#{name_str}\n  Memory: #{mem_kb} KB\n  Reductions: #{proc.reductions}\n  Message Queue: #{proc.message_queue}\n  Current: #{proc.current_function}"
          end)
          |> Enum.join("\n\n")

        header <> procs_text
      end

    %{
      content: [
        %{
          type: "text",
          text: result_text
        }
      ]
    }
  end

  defp handle_beam_system_info(_args) do
    info = %{
      otp_release: :erlang.system_info(:otp_release),
      version: :erlang.system_info(:version),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      logical_processors: :erlang.system_info(:logical_processors),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      ets_limit: :erlang.system_info(:ets_limit),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit)
    }

    result_text = """
    BEAM VM System Information:

    OTP Release:           #{info.otp_release}
    ERTS Version:          #{info.version}

    Schedulers:
      Total:               #{info.schedulers}
      Online:              #{info.schedulers_online}
      Logical Processors:  #{info.logical_processors || "unknown"}

    Processes:
      Current:             #{info.process_count}
      Limit:               #{info.process_limit}

    Ports:
      Current:             #{info.port_count}
      Limit:               #{info.port_limit}

    ETS Tables:
      Limit:               #{info.ets_limit}

    Atoms:
      Current:             #{info.atom_count}
      Limit:               #{info.atom_limit}
    """

    %{
      content: [
        %{
          type: "text",
          text: result_text
        }
      ]
    }
  end

  defp handle_beam_schedulers(_args) do
    schedulers_online = :erlang.system_info(:schedulers_online)
    schedulers_total = :erlang.system_info(:schedulers)

    # Get scheduler statistics using erlang:statistics/1
    stats = :erlang.statistics(:scheduler_wall_time)
    Process.sleep(1000)
    stats2 = :erlang.statistics(:scheduler_wall_time)

    result_text = """
    BEAM Scheduler Information:

    Schedulers Total:  #{schedulers_total}
    Schedulers Online: #{schedulers_online}

    """

    scheduler_details =
      if stats && stats2 do
        utilizations = calculate_scheduler_utilization(stats, stats2)

        details =
          utilizations
          |> Enum.map(fn {id, util} ->
            percent = Float.round(util * 100, 2)
            "  Scheduler #{id}: #{percent}%"
          end)
          |> Enum.join("\n")

        avg_util =
          if length(utilizations) > 0 do
            avg = utilizations |> Enum.map(fn {_, util} -> util end) |> Enum.sum() |> Kernel./(length(utilizations))
            Float.round(avg * 100, 2)
          else
            0.0
          end

        "Scheduler Utilization (1 second sample):\n#{details}\n\nAverage Utilization: #{avg_util}%"
      else
        "Scheduler wall time statistics not available (enable with: :erlang.system_flag(:scheduler_wall_time, true))"
      end

    %{
      content: [
        %{
          type: "text",
          text: result_text <> scheduler_details
        }
      ]
    }
  end

  defp calculate_scheduler_utilization(stats1, stats2) do
    Enum.zip(stats1, stats2)
    |> Enum.map(fn {{id, active1, total1}, {id, active2, total2}} ->
      active_diff = active2 - active1
      total_diff = total2 - total1

      utilization =
        if total_diff > 0 do
          active_diff / total_diff
        else
          0.0
        end

      {id, utilization}
    end)
  end

  defp handle_beam_applications(_args) do
    apps =
      Application.loaded_applications()
      |> Enum.map(fn {app, desc, version} ->
        status = if Application.started_applications() |> Enum.any?(fn {a, _, _} -> a == app end), do: "started", else: "loaded"
        %{name: app, description: desc, version: version, status: status}
      end)
      |> Enum.sort_by(& &1.name)

    result_text =
      if Enum.empty?(apps) do
        "No applications loaded"
      else
        header = "OTP Applications (#{length(apps)}):\n\n"

        apps_text =
          apps
          |> Enum.map(fn app ->
            status_indicator = if app.status == "started", do: "✓", else: "○"
            "#{status_indicator} #{app.name} (#{app.version})\n  #{app.description}"
          end)
          |> Enum.join("\n\n")

        header <> apps_text
      end

    %{
      content: [
        %{
          type: "text",
          text: result_text
        }
      ]
    }
  end

  defp handle_beam_ets_tables(args) do
    limit = Map.get(args, "limit", 20)

    tables =
      :ets.all()
      |> Enum.map(fn table ->
        try do
          info = :ets.info(table)

          %{
            name: info[:name] || table,
            size: info[:size] || 0,
            memory: info[:memory] || 0,
            type: info[:type],
            protection: info[:protection],
            owner: inspect(info[:owner])
          }
        rescue
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.memory, :desc)
      |> Enum.take(limit)

    result_text =
      if Enum.empty?(tables) do
        "No ETS tables found"
      else
        header = "ETS Tables (top #{length(tables)} by memory):\n\n"

        tables_text =
          tables
          |> Enum.map(fn table ->
            mem_kb = Float.round(table.memory * :erlang.system_info(:wordsize) / 1024, 2)
            "#{table.name}\n  Size: #{table.size} objects\n  Memory: #{mem_kb} KB\n  Type: #{table.type}, Protection: #{table.protection}\n  Owner: #{table.owner}"
          end)
          |> Enum.join("\n\n")

        header <> tables_text
      end

    %{
      content: [
        %{
          type: "text",
          text: result_text
        }
      ]
    }
  end

  defp format_function({module, function, arity}) do
    "#{module}.#{function}/#{arity}"
  end

  defp format_function(_), do: "unknown"
end

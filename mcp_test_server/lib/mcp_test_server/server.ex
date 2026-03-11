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
          version: "0.2.0"
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
end

defmodule McpTestServer.Servers.Filesystem do
  @moduledoc """
  MCP server providing filesystem tools scoped to a configurable workspace directory.

  All paths are validated against the workspace root to prevent directory traversal.
  Configure the workspace via the `:workspace_path` application env key
  (defaults to `/tmp/mcp_workspace`).
  """

  @behaviour McpTestServer.ServerBehaviour

  @impl true
  def server_name, do: "mcp-filesystem"

  @impl true
  def list_tools do
    [
      %{
        name: "read_file",
        description: "Read the contents of a file from the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to the file relative to workspace"}
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
            path: %{type: "string", description: "Path to the file relative to workspace"},
            content: %{type: "string", description: "Content to write to the file"}
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
        description: "Get metadata about a file or directory",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path relative to workspace"}
          },
          required: ["path"]
        }
      },
      %{
        name: "create_directory",
        description: "Create a directory (and any missing parents) in the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Directory path relative to workspace"}
          },
          required: ["path"]
        }
      },
      %{
        name: "move_file",
        description: "Move or rename a file within the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            source: %{type: "string", description: "Source path relative to workspace"},
            destination: %{type: "string", description: "Destination path relative to workspace"}
          },
          required: ["source", "destination"]
        }
      },
      %{
        name: "copy_file",
        description: "Copy a file within the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            source: %{type: "string", description: "Source path relative to workspace"},
            destination: %{type: "string", description: "Destination path relative to workspace"}
          },
          required: ["source", "destination"]
        }
      },
      %{
        name: "delete_file",
        description: "Delete a single file from the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to the file relative to workspace"}
          },
          required: ["path"]
        }
      },
      %{
        name: "delete_directory",
        description: "Delete a directory and all its contents from the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to the directory relative to workspace"}
          },
          required: ["path"]
        }
      },
      %{
        name: "search_files",
        description: "Search for files matching a pattern within the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "Filename pattern (supports * and ? wildcards)"
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
        description: "Get the size of a file in the workspace",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to the file relative to workspace"}
          },
          required: ["path"]
        }
      },
      %{
        name: "delete_files",
        description: "Delete multiple files in a single operation",
        inputSchema: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "List of file paths relative to workspace"
            }
          },
          required: ["paths"]
        }
      },
      %{
        name: "delete_directories",
        description: "Delete multiple directories in a single operation",
        inputSchema: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "List of directory paths relative to workspace"
            }
          },
          required: ["paths"]
        }
      },
      %{
        name: "delete_files_by_pattern",
        description: "Delete all files matching a wildcard pattern",
        inputSchema: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "Filename pattern (supports * and ? wildcards)"
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
        description: "Delete all directories matching a pattern in a given directory",
        inputSchema: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "Directory name pattern (supports * and ? wildcards)"
            },
            path: %{
              type: "string",
              description: "Parent directory to search in (default: workspace root)",
              default: "."
            }
          },
          required: ["pattern"]
        }
      },
      %{
        name: "copy_files",
        description: "Copy multiple files in a single operation",
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
              description: "List of copy operations, each with source and destination"
            }
          },
          required: ["operations"]
        }
      },
      %{
        name: "move_files",
        description: "Move multiple files in a single operation",
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
              description: "List of move operations, each with source and destination"
            }
          },
          required: ["operations"]
        }
      }
    ]
  end

  @impl true
  def execute_tool(tool_name, arguments) do
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
      "delete_files" -> handle_delete_files(arguments)
      "delete_directories" -> handle_delete_directories(arguments)
      "delete_files_by_pattern" -> handle_delete_files_by_pattern(arguments)
      "delete_directories_by_pattern" -> handle_delete_directories_by_pattern(arguments)
      "copy_files" -> handle_copy_files(arguments)
      "move_files" -> handle_move_files(arguments)
      _ -> %{isError: true, content: [%{type: "text", text: "Unknown tool: #{tool_name}"}]}
    end
  end

  # Handlers

  defp handle_read_file(%{"path" => path}) do
    workspace = get_workspace()

    case resolve_path(path, workspace) do
      {:ok, full_path} ->
        case File.read(full_path) do
          {:ok, content} ->
            %{content: [%{type: "text", text: "File: #{path}\n\n#{content}"}]}

          {:error, :enoent} ->
            %{isError: true, content: [%{type: "text", text: "File not found: #{path}"}]}

          {:error, reason} ->
            %{isError: true, content: [%{type: "text", text: "Error reading file: #{inspect(reason)}"}]}
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_write_file(%{"path" => path, "content" => content}) do
    workspace = get_workspace()

    case resolve_path(path, workspace) do
      {:ok, full_path} ->
        full_path |> Path.dirname() |> File.mkdir_p!()

        case File.write(full_path, content) do
          :ok ->
            %{
              content: [
                %{type: "text", text: "Successfully wrote #{byte_size(content)} bytes to #{path}"}
              ]
            }

          {:error, reason} ->
            %{isError: true, content: [%{type: "text", text: "Error writing file: #{inspect(reason)}"}]}
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_list_directory(args) do
    path = Map.get(args, "path", ".")
    workspace = get_workspace()

    case resolve_path(path, workspace) do
      {:ok, full_path} ->
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

            %{content: [%{type: "text", text: "Directory: #{path}\n\n#{entries_text}"}]}

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

    case resolve_path(path, workspace) do
      {:ok, full_path} ->
        case File.stat(full_path) do
          {:ok, stat} ->
            info = """
            File Information: #{path}

            Type: #{stat.type}
            Size: #{format_size(stat.size)} (#{stat.size} bytes)
            Access: #{stat.access}
            Modified: #{format_datetime(stat.mtime)}
            """

            %{content: [%{type: "text", text: info}]}

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

  defp handle_create_directory(%{"path" => path}) do
    workspace = get_workspace()

    case resolve_path(path, workspace) do
      {:ok, full_path} ->
        case File.mkdir_p(full_path) do
          :ok ->
            %{content: [%{type: "text", text: "Created directory: #{path}"}]}

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

    with {:ok, source_path} <- resolve_path(source, workspace),
         {:ok, dest_path} <- resolve_path(destination, workspace) do
      dest_path |> Path.dirname() |> File.mkdir_p!()

      case File.rename(source_path, dest_path) do
        :ok ->
          %{content: [%{type: "text", text: "Moved: #{source} -> #{destination}"}]}

        {:error, reason} ->
          %{isError: true, content: [%{type: "text", text: "Error moving file: #{inspect(reason)}"}]}
      end
    else
      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_copy_file(%{"source" => source, "destination" => destination}) do
    workspace = get_workspace()

    with {:ok, source_path} <- resolve_path(source, workspace),
         {:ok, dest_path} <- resolve_path(destination, workspace) do
      dest_path |> Path.dirname() |> File.mkdir_p!()

      case File.cp(source_path, dest_path) do
        :ok ->
          %{content: [%{type: "text", text: "Copied: #{source} -> #{destination}"}]}

        {:error, reason} ->
          %{isError: true, content: [%{type: "text", text: "Error copying file: #{inspect(reason)}"}]}
      end
    else
      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_delete_file(%{"path" => path}) do
    workspace = get_workspace()

    case resolve_path(path, workspace) do
      {:ok, full_path} ->
        case File.rm(full_path) do
          :ok ->
            %{content: [%{type: "text", text: "Deleted file: #{path}"}]}

          {:error, :enoent} ->
            %{isError: true, content: [%{type: "text", text: "File not found: #{path}"}]}

          {:error, reason} ->
            %{isError: true, content: [%{type: "text", text: "Error deleting file: #{inspect(reason)}"}]}
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_delete_directory(%{"path" => path}) do
    workspace = get_workspace()

    case resolve_path(path, workspace) do
      {:ok, full_path} ->
        case File.rm_rf(full_path) do
          {:ok, _files} ->
            %{content: [%{type: "text", text: "Deleted directory: #{path}"}]}

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

  defp handle_delete_files(%{"paths" => paths}) when is_list(paths) do
    workspace = get_workspace()

    results =
      Enum.map(paths, fn path ->
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

    format_batch_result(results, "file", "files")
  end

  defp handle_delete_directories(%{"paths" => paths}) when is_list(paths) do
    workspace = get_workspace()

    results =
      Enum.map(paths, fn path ->
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

    format_batch_result(results, "directory", "directories")
  end

  defp handle_delete_files_by_pattern(%{"pattern" => pattern} = args) do
    workspace = get_workspace()
    search_path = Map.get(args, "path", ".")
    full_search_path = Path.join(workspace, search_path)

    case validate_path(full_search_path, workspace) do
      :ok ->
        full_pattern = Path.join(full_search_path, pattern)
        files = full_pattern |> Path.wildcard() |> Enum.filter(&File.regular?/1)

        if Enum.empty?(files) do
          %{content: [%{type: "text", text: "No files found matching pattern: #{pattern}"}]}
        else
          results =
            Enum.map(files, fn full_path ->
              relative = Path.relative_to(full_path, workspace)

              case File.rm(full_path) do
                :ok -> {:ok, relative}
                {:error, reason} -> {:error, relative, inspect(reason)}
              end
            end)

          format_batch_result(results, "file", "files")
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
        case File.ls(full_search_path) do
          {:ok, entries} ->
            matching =
              Enum.filter(entries, fn entry ->
                full_entry = Path.join(full_search_path, entry)
                File.dir?(full_entry) and String.match?(entry, pattern_to_regex(pattern))
              end)

            if Enum.empty?(matching) do
              %{content: [%{type: "text", text: "No directories found matching pattern: #{pattern}"}]}
            else
              results =
                Enum.map(matching, fn dir ->
                  full_path = Path.join(full_search_path, dir)
                  relative = Path.relative_to(full_path, workspace)

                  case File.rm_rf(full_path) do
                    {:ok, _} -> {:ok, relative}
                    {:error, reason, _} -> {:error, relative, inspect(reason)}
                  end
                end)

              format_batch_result(results, "directory", "directories")
            end

          {:error, reason} ->
            %{isError: true, content: [%{type: "text", text: "Error reading directory: #{inspect(reason)}"}]}
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  defp handle_copy_files(%{"operations" => operations}) when is_list(operations) do
    workspace = get_workspace()

    results =
      Enum.map(operations, fn op ->
        source = Map.get(op, "source")
        destination = Map.get(op, "destination")
        label = "#{source} → #{destination}"

        if is_nil(source) or is_nil(destination) do
          {:error, label, "missing source or destination"}
        else
          source_full = Path.join(workspace, source)
          dest_full = Path.join(workspace, destination)

          with :ok <- validate_path(source_full, workspace),
               :ok <- validate_path(dest_full, workspace) do
            case File.copy(source_full, dest_full) do
              {:ok, _bytes} -> {:ok, label}
              {:error, reason} -> {:error, label, inspect(reason)}
            end
          else
            {:error, reason} -> {:error, label, reason}
          end
        end
      end)

    format_batch_result(results, "file", "files", verb: "copied")
  end

  defp handle_move_files(%{"operations" => operations}) when is_list(operations) do
    workspace = get_workspace()

    results =
      Enum.map(operations, fn op ->
        source = Map.get(op, "source")
        destination = Map.get(op, "destination")
        label = "#{source} → #{destination}"

        if is_nil(source) or is_nil(destination) do
          {:error, label, "missing source or destination"}
        else
          source_full = Path.join(workspace, source)
          dest_full = Path.join(workspace, destination)

          with :ok <- validate_path(source_full, workspace),
               :ok <- validate_path(dest_full, workspace) do
            case File.rename(source_full, dest_full) do
              :ok -> {:ok, label}
              {:error, reason} -> {:error, label, inspect(reason)}
            end
          else
            {:error, reason} -> {:error, label, reason}
          end
        end
      end)

    format_batch_result(results, "file", "files", verb: "moved")
  end

  defp handle_search_files(%{"pattern" => pattern} = args) do
    workspace = get_workspace()
    search_path = Map.get(args, "path", ".")
    full_path = Path.join(workspace, search_path)

    case validate_path(full_path, workspace) do
      :ok ->
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
              |> Enum.filter(fn p -> File.regular?(p) && Regex.match?(regex, Path.basename(p)) end)
              |> Enum.map(&Path.relative_to(&1, workspace))

            result_text =
              if Enum.empty?(matches) do
                "No files found matching pattern: #{pattern}"
              else
                "Found #{length(matches)} file(s):\n" <> Enum.join(matches, "\n")
              end

            %{content: [%{type: "text", text: result_text}]}

          {:error, reason} ->
            %{isError: true, content: [%{type: "text", text: "Invalid pattern: #{inspect(reason)}"}]}
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
            %{content: [%{type: "text", text: "File: #{path}\nSize: #{format_size(size)} (#{size} bytes)"}]}

          {:ok, %{type: :directory}} ->
            %{isError: true, content: [%{type: "text", text: "Path is a directory, not a file: #{path}"}]}

          {:error, :enoent} ->
            %{isError: true, content: [%{type: "text", text: "File not found: #{path}"}]}

          {:error, reason} ->
            %{isError: true, content: [%{type: "text", text: "Error getting file size: #{inspect(reason)}"}]}
        end

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: reason}]}
    end
  end

  # Shared Helpers

  defp get_workspace do
    Application.get_env(:mcp_test_server, :workspace_path, "/tmp/mcp_workspace")
  end

  # Resolve a path (absolute or relative) against the workspace root.
  # Returns {:ok, full_path} if the path is within the workspace,
  # or {:error, reason} if validation fails.
  #
  # Supports:
  # - Absolute paths: "/Users/mcbaneh/devel/ollama_chat/file.txt"
  # - Relative paths: "ollama_chat/file.txt"
  # - Workspace root: "." or ""
  # - Tilde expansion: "~/devel/ollama_chat/file.txt"
  # - Environment variables: "$HOME/devel/file.txt" or "${HOME}/devel/file.txt"
  #
  defp resolve_path(path, workspace) do
    # First, expand ~ and environment variables
    expanded_path = expand_path_variables(path)

    full_path =
      if Path.type(expanded_path) == :absolute do
        # Absolute path: use it directly
        expanded_path
      else
        # Relative path: join with workspace
        Path.join(workspace, expanded_path)
      end

    # Expand to resolve any . or .. segments
    real_path = Path.expand(full_path)
    real_workspace = Path.expand(workspace)

    # Ensure the trailing slash for proper prefix checking
    real_workspace = Path.join(real_workspace, "")

    if String.starts_with?(real_path, real_workspace) or real_path == String.trim_trailing(real_workspace, "/") do
      {:ok, real_path}
    else
      {:error, "Access denied: path outside workspace (#{path} -> #{real_path} not under #{real_workspace})"}
    end
  end

  # Expand tilde (~) and environment variables in a path.
  # Supports: ~, ~/path, $VAR, ${VAR}
  defp expand_path_variables(path) do
    path
    |> expand_tilde()
    |> expand_env_vars()
  end

  # Expand tilde to home directory
  defp expand_tilde("~" <> rest) do
    case System.get_env("HOME") do
      nil -> "~" <> rest  # No HOME env var, return unchanged
      home -> Path.join(home, String.trim_leading(rest, "/"))
    end
  end
  defp expand_tilde(path), do: path

  # Expand environment variables: $VAR and ${VAR}
  defp expand_env_vars(path) do
    # Replace ${VAR} first (greedy)
    path = Regex.replace(~r/\$\{([A-Z_][A-Z0-9_]*)\}/, path, fn _, var ->
      System.get_env(var) || "${#{var}}"
    end)

    # Then replace $VAR (non-greedy, stop at / or end of string)
    Regex.replace(~r/\$([A-Z_][A-Z0-9_]*)(?=\/|$)/, path, fn _, var ->
      System.get_env(var) || "$#{var}"
    end)
  end

  # Legacy validate_path for backward compatibility
  defp validate_path(full_path, workspace) do
    real_path = Path.expand(full_path)
    real_workspace = Path.expand(workspace)

    if String.starts_with?(real_path, real_workspace) do
      :ok
    else
      {:error, "Access denied: path outside workspace"}
    end
  end

  defp pattern_to_regex(pattern) do
    escaped = Regex.escape(pattern)

    regex_pattern =
      escaped
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    ~r/^#{regex_pattern}$/
  end

  defp format_batch_result(results, singular, plural, opts \\ []) do
    verb = Keyword.get(opts, :verb, "deleted")
    successful = Enum.filter(results, fn {status, _} -> status == :ok end)
    failed = Enum.filter(results, fn {status, _} -> status == :error end)
    success_count = length(successful)
    fail_count = length(failed)

    text =
      cond do
        fail_count == 0 ->
          items = Enum.map_join(successful, "\n", fn {:ok, p} -> "  ✓ #{p}" end)
          noun = if success_count == 1, do: singular, else: plural
          "Successfully #{verb} #{success_count} #{noun}:\n#{items}"

        success_count == 0 ->
          details = Enum.map_join(failed, "\n", fn {:error, p, r} -> "  ✗ #{p}: #{r}" end)
          "Failed to #{String.replace(verb, "d", "")} all #{plural}:\n#{details}"

        true ->
          success_list = Enum.map_join(successful, "\n", fn {:ok, p} -> "  ✓ #{p}" end)
          error_list = Enum.map_join(failed, "\n", fn {:error, p, r} -> "  ✗ #{p}: #{r}" end)
          noun = if success_count == 1, do: singular, else: plural
          "#{String.capitalize(verb)} #{success_count} #{noun}, #{fail_count} failed:\nSuccessful:\n#{success_list}\nFailed:\n#{error_list}"
      end

    if fail_count > 0 and success_count == 0 do
      %{isError: true, content: [%{type: "text", text: text}]}
    else
      %{content: [%{type: "text", text: text}]}
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 2)}KB"
  defp format_size(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 2)}MB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)}GB"

  defp format_datetime({{year, month, day}, {hour, minute, second}}) do
    "#{year}-#{pad(month)}-#{pad(day)} #{pad(hour)}:#{pad(minute)}:#{pad(second)}"
  end

  defp pad(num) when num < 10, do: "0#{num}"
  defp pad(num), do: "#{num}"
end

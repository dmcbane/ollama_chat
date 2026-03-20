defmodule McpTestServer.Servers.Memory do
  @moduledoc """
  MCP server providing an in-memory key/value store with optional TTL support.

  Values persist for the lifetime of the server process. Uses
  McpTestServer.MemoryStore (a GenServer) for thread-safe access and
  automatic expiry of TTL-bound entries.
  """

  @behaviour McpTestServer.ServerBehaviour

  @impl true
  def server_name, do: "mcp-memory"

  @impl true
  def list_tools do
    [
      %{
        name: "memory_set",
        description: "Store a value in memory with an optional time-to-live",
        inputSchema: %{
          type: "object",
          properties: %{
            key: %{type: "string", description: "Key to store the value under"},
            value: %{type: "string", description: "Value to store"},
            ttl: %{
              type: "integer",
              description: "Optional time-to-live in seconds. Omit for no expiry."
            }
          },
          required: ["key", "value"]
        }
      },
      %{
        name: "memory_get",
        description: "Retrieve a previously stored value by key",
        inputSchema: %{
          type: "object",
          properties: %{
            key: %{type: "string", description: "Key to retrieve"}
          },
          required: ["key"]
        }
      },
      %{
        name: "memory_delete",
        description: "Delete a stored value by key",
        inputSchema: %{
          type: "object",
          properties: %{
            key: %{type: "string", description: "Key to delete"}
          },
          required: ["key"]
        }
      },
      %{
        name: "memory_list",
        description: "List all keys currently stored in memory",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      }
    ]
  end

  @impl true
  def execute_tool(tool_name, arguments) do
    case tool_name do
      "memory_set" -> handle_memory_set(arguments)
      "memory_get" -> handle_memory_get(arguments)
      "memory_delete" -> handle_memory_delete(arguments)
      "memory_list" -> handle_memory_list(arguments)
      _ -> %{isError: true, content: [%{type: "text", text: "Unknown tool: #{tool_name}"}]}
    end
  end

  # Handlers

  defp handle_memory_set(%{"key" => key, "value" => value} = args) do
    ttl = Map.get(args, "ttl")

    case McpTestServer.MemoryStore.set(key, value, ttl) do
      :ok ->
        ttl_info = if ttl, do: " (TTL: #{ttl}s)", else: ""
        %{content: [%{type: "text", text: "Stored value for key '#{key}'#{ttl_info}"}]}

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end

  defp handle_memory_get(%{"key" => key}) do
    case McpTestServer.MemoryStore.get(key) do
      {:ok, value} ->
        %{content: [%{type: "text", text: "Value for key '#{key}':\n#{value}"}]}

      {:error, :not_found} ->
        %{isError: true, content: [%{type: "text", text: "Key not found: #{key}"}]}

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end

  defp handle_memory_delete(%{"key" => key}) do
    case McpTestServer.MemoryStore.delete(key) do
      :ok ->
        %{content: [%{type: "text", text: "Deleted key '#{key}'"}]}

      {:error, :not_found} ->
        %{isError: true, content: [%{type: "text", text: "Key not found: #{key}"}]}

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end

  defp handle_memory_list(_args) do
    case McpTestServer.MemoryStore.list_keys() do
      {:ok, []} ->
        %{content: [%{type: "text", text: "No keys stored in memory"}]}

      {:ok, keys} ->
        keys_text = keys |> Enum.sort() |> Enum.join("\n")
        %{content: [%{type: "text", text: "Stored keys (#{length(keys)}):\n#{keys_text}"}]}

      {:error, reason} ->
        %{isError: true, content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
    end
  end
end

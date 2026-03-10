defmodule McpTestServer do
  @moduledoc """
  MCP Test Server - A comprehensive Elixir-based MCP server for testing.

  This server implements multiple tool categories similar to the reference
  Model Context Protocol servers, but built entirely in Elixir/BEAM.

  ## Tool Categories

  ### Filesystem Tools
  - `read_file` - Read file contents from workspace
  - `write_file` - Write content to files in workspace
  - `list_directory` - List directory contents
  - `file_info` - Get detailed file/directory information

  ### Memory/KV Tools
  - `memory_set` - Store key-value pairs with optional TTL
  - `memory_get` - Retrieve stored values
  - `memory_delete` - Delete stored values
  - `memory_list` - List all stored keys

  ### Utility Tools
  - `echo` - Echo back provided text
  - `get_time` - Get current server time
  - `random_number` - Generate random numbers
  - `hash_text` - Generate cryptographic hashes

  ## Configuration

  Configure the workspace path in your config:

      config :mcp_test_server,
        workspace_path: "/path/to/workspace"

  ## Starting the Server

  The server starts automatically as part of the application supervision tree.
  You can also start it manually:

      {:ok, _pid} = McpTestServer.Application.start(:normal, [])

  ## Usage with Ollama Chat

  Add this server to your MCP configuration:

      config :ollama_chat, :mcp_servers, [
        %{
          name: :test_server,
          display_name: "Test Server",
          command: "elixir",
          args: ["-S", "mix", "run", "--no-halt"],
          working_dir: "/path/to/mcp_test_server",
          env: %{},
          requires_approval: false
        }
      ]
  """

  @doc """
  Returns the version of the MCP Test Server.
  """
  def version, do: "0.1.0"

  @doc """
  Returns information about the server and available tools.
  """
  def info do
    %{
      name: "MCP Test Server",
      version: version(),
      description:
        "Comprehensive Elixir-based MCP server with filesystem, memory, and utility tools",
      tool_count: 12,
      categories: [:filesystem, :memory, :utility]
    }
  end
end

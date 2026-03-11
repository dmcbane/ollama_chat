defmodule McpTestServer.Application do
  @moduledoc """
  Main application supervisor for the MCP Test Server.

  This server implements multiple MCP capabilities including:
  - Filesystem operations (read, write, list)
  - Memory/KV store (set, get, delete)
  - Utility tools (echo, time, random)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Memory store for the KV functionality
      {McpTestServer.MemoryStore, []},
      # MCP Server supervisor
      {McpTestServer.Server, []}
    ]

    opts = [strategy: :one_for_one, name: McpTestServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

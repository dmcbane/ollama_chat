defmodule McpTestServer.Application do
  @moduledoc """
  Main application supervisor for the MCP Test Server.

  The server to run is selected by the `MCP_SERVER` environment variable:

    MCP_SERVER=filesystem mix run --no-halt   # file operations (default)
    MCP_SERVER=memory     mix run --no-halt   # in-memory KV store
    MCP_SERVER=system     mix run --no-halt   # BEAM monitoring, env, utilities
    MCP_SERVER=web        mix run --no-halt   # web search via DuckDuckGo
  """
  use Application

  @impl true
  def start(_type, _args) do
    server_module = select_server_module()
    children = build_children(server_module)
    opts = [strategy: :one_for_one, name: McpTestServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp select_server_module do
    case System.get_env("MCP_SERVER", "filesystem") do
      "filesystem" -> McpTestServer.Servers.Filesystem
      "memory" -> McpTestServer.Servers.Memory
      "system" -> McpTestServer.Servers.System
      "web" -> McpTestServer.Servers.Web
      other -> raise "Unknown MCP_SERVER=#{other}. Valid values: filesystem, memory, system, web"
    end
  end

  # The memory server needs the MemoryStore GenServer running alongside it.
  defp build_children(McpTestServer.Servers.Memory) do
    [
      {McpTestServer.MemoryStore, []},
      {McpTestServer.StdioServer, McpTestServer.Servers.Memory}
    ]
  end

  defp build_children(server_module) do
    [{McpTestServer.StdioServer, server_module}]
  end
end

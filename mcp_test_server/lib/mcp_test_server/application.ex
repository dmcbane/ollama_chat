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
    # Configure workspace path from command-line arguments (if provided)
    configure_workspace_from_argv()

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

  # Configure workspace path from command-line arguments.
  # When MCP clients pass a root_path, it arrives as an additional argument
  # after the server name. We configure it in the Application environment so
  # the filesystem server can read it via Application.get_env/3.
  defp configure_workspace_from_argv do
    case System.argv() do
      # First argument after server name is the workspace path
      [workspace_path | _] when is_binary(workspace_path) and workspace_path != "" ->
        expanded = Path.expand(workspace_path)

        if File.dir?(expanded) do
          Application.put_env(:mcp_test_server, :workspace_path, expanded)
          IO.puts(:stderr, "MCP Filesystem workspace: #{expanded}")
        else
          IO.puts(
            :stderr,
            "Warning: workspace path #{workspace_path} does not exist, using default"
          )
        end

      _ ->
        # No workspace argument provided, use default
        :ok
    end
  end
end

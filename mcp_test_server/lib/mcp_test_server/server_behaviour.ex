defmodule McpTestServer.ServerBehaviour do
  @moduledoc """
  Behaviour for MCP server implementations.

  Each server module implements these three callbacks to integrate with the
  shared McpTestServer.StdioServer protocol handler. The StdioServer owns
  the stdio loop and JSON-RPC 2.0 framing; server modules own only tool
  definitions and execution logic.
  """

  @doc "Returns the MCP server name reported in the `initialize` response."
  @callback server_name() :: String.t()

  @doc "Returns the list of tool definition maps for this server."
  @callback list_tools() :: [map()]

  @doc "Executes a named tool with the given arguments map."
  @callback execute_tool(tool_name :: String.t(), arguments :: map()) :: map()
end

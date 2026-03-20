defmodule McpTestServer.StdioServer do
  @moduledoc """
  Shared stdio transport and JSON-RPC 2.0 protocol handler for MCP servers.

  This GenServer spawns a stdio loop process and delegates tool listing and
  execution to the configured server module (any module implementing
  McpTestServer.ServerBehaviour). It owns the full MCP protocol layer so
  individual server modules can stay purely functional.
  """

  use GenServer

  @server_version "0.4.0"

  def start_link(server_module) do
    GenServer.start_link(__MODULE__, server_module, name: __MODULE__)
  end

  @impl true
  def init(server_module) do
    spawn_link(fn -> stdio_loop(server_module) end)
    {:ok, server_module}
  end

  # Stdio Loop

  defp stdio_loop(server_module) do
    case IO.read(:stdio, :line) do
      :eof ->
        System.halt(0)

      {:error, _reason} ->
        stdio_loop(server_module)

      line when is_binary(line) ->
        line = String.trim(line)
        if line != "", do: handle_request(line, server_module)
        stdio_loop(server_module)
    end
  end

  defp handle_request(line, server_module) do
    case Jason.decode(line) do
      {:ok, request} ->
        send_response(process_request(request, server_module))

      {:error, _reason} ->
        send_response(%{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: -32700, message: "Parse error"}
        })
    end
  end

  # JSON-RPC 2.0 Request Dispatch

  defp process_request(
         %{"method" => "initialize", "id" => id, "params" => _params},
         server_module
       ) do
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        protocolVersion: "2024-11-05",
        serverInfo: %{name: server_module.server_name(), version: @server_version},
        capabilities: %{tools: %{listChanged: true}}
      }
    }
  end

  defp process_request(%{"method" => "initialize", "id" => id}, server_module) do
    process_request(%{"method" => "initialize", "id" => id, "params" => %{}}, server_module)
  end

  defp process_request(%{"method" => "tools/list", "id" => id}, server_module) do
    %{jsonrpc: "2.0", id: id, result: %{tools: server_module.list_tools()}}
  end

  defp process_request(
         %{"method" => "tools/call", "id" => id, "params" => params},
         server_module
       ) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}
    result = server_module.execute_tool(tool_name, arguments)
    %{jsonrpc: "2.0", id: id, result: result}
  end

  defp process_request(%{"method" => _method, "id" => id}, _server_module) do
    %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "Method not found"}}
  end

  defp process_request(_request, _server_module) do
    %{jsonrpc: "2.0", id: nil, error: %{code: -32600, message: "Invalid request"}}
  end

  defp send_response(response) do
    IO.puts(Jason.encode!(response))
  end
end

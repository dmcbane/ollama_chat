defmodule OllamaChat.ToolRouter do
  @moduledoc """
  Routes tool calls to the appropriate executor.

  Built-in tools (memory management) execute in-process.
  MCP tools execute via external server processes through MCPClient.

  ## Routing Priority

  1. If the tool name is registered as a built-in, it is executed in-process.
  2. Otherwise, the call is forwarded to `OllamaChat.MCPClient`.

  This means built-in tool names take precedence over MCP tools of the same name.
  """

  alias OllamaChat.BuiltinTools.Registry, as: BuiltinRegistry
  alias OllamaChat.MCPClient

  require Logger

  @doc """
  Routes a tool call to the correct executor and returns the result.

  Returns `{:ok, result_text}` on success or `{:error, reason}` on failure.

  Built-in tools always return `{:ok, String.t()}` or `{:error, String.t()}`.
  MCP tools return the raw MCPClient result, which may be a struct or list.

  ## Parameters

    - name: The tool name string (e.g. `"memory_save"`, `"read_file"`)
    - arguments: Map of argument name → value

  ## Examples

      iex> ToolRouter.route_tool_call("memory_save", %{"content" => "User likes Elixir"})
      {:ok, "Memory saved: \\"User likes Elixir\\" (fact, importance: 0.5)"}

      iex> ToolRouter.route_tool_call("read_file", %{"path" => "README.md"})
      # Delegates to MCPClient

  """
  @spec route_tool_call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def route_tool_call(name, arguments) when is_binary(name) and is_map(arguments) do
    if BuiltinRegistry.builtin_tool?(name) do
      Logger.debug("Routing #{name} to built-in executor")
      execute_builtin(name, arguments)
    else
      Logger.debug("Routing #{name} to MCP executor")
      execute_mcp(name, arguments)
    end
  end

  def route_tool_call(name, _arguments) do
    {:error, "Invalid tool name: #{inspect(name)}"}
  end

  @doc """
  Returns `true` if the given tool name is handled by either a built-in
  or an active MCP tool. Useful for fast existence checks before routing.
  """
  @spec known_tool?(String.t(), map()) :: boolean()
  def known_tool?(name, mcp_tools \\ %{}) when is_binary(name) do
    BuiltinRegistry.builtin_tool?(name) or Map.has_key?(mcp_tools, name)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp execute_builtin(name, arguments) do
    tool_module = BuiltinRegistry.get_tool(name)

    if tool_module do
      tool_module.execute(arguments)
    else
      {:error, "Built-in tool not found: #{name}"}
    end
  end

  defp execute_mcp(name, arguments) do
    case MCPClient.call_tool(name, arguments) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end

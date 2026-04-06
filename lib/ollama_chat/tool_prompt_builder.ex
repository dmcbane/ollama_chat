defmodule OllamaChat.ToolPromptBuilder do
  @moduledoc """
  Builds system prompts for the LLM that include all available tools —
  both built-in tools (memory management) and MCP tools (external servers).

  Wraps `MCPPromptBuilder` to transparently inject built-in tool descriptions
  alongside any MCP tools, so the LLM sees a unified tool list regardless of
  which backend will execute each call.

  ## Tool Priority

  When an MCP tool and a built-in tool share the same name, the MCP tool takes
  precedence (it overrides the built-in entry in the merged map). This lets
  operators shadow built-in tools via MCP if needed.

  ## Memory Availability

  Built-in memory tools are only included when `OllamaChat.Memory.available?/0`
  returns `true`. If the database is down or memory is disabled, the prompt
  falls back to MCP-only (or a bare system prompt if MCP has no tools either).
  """

  alias OllamaChat.BuiltinTools.Registry, as: BuiltinRegistry
  alias OllamaChat.MCPPromptBuilder
  alias OllamaChat.Memory

  @doc """
  Builds a tool-aware system prompt that includes both built-in and MCP tools.

  Built-in memory tools are injected automatically when `Memory.available?/0`
  is `true`. MCP tools are passed in explicitly.

  Returns the same string format as `MCPPromptBuilder.build_tool_aware_system_prompt/2`.

  ## Parameters

    - `mcp_tools` — Map of MCP tool names → tool-info maps (may be empty)
    - `base_prompt` — Optional base system prompt to prepend (default: `nil`)

  ## Examples

      iex> ToolPromptBuilder.build_tool_aware_system_prompt(%{}, nil)
      # Returns a prompt listing only memory tools (when memory is available)

      iex> ToolPromptBuilder.build_tool_aware_system_prompt(mcp_tools, "Be concise.")
      # Returns a prompt listing both memory tools and mcp_tools

  """
  @spec build_tool_aware_system_prompt(map(), String.t() | nil) :: String.t()
  def build_tool_aware_system_prompt(mcp_tools, base_prompt \\ nil) when is_map(mcp_tools) do
    all_tools = merge_with_builtin_tools(mcp_tools)
    MCPPromptBuilder.build_tool_aware_system_prompt(all_tools, base_prompt)
  end

  @doc """
  Returns `true` when at least one tool is available — either a built-in tool
  (memory system reachable) or at least one MCP tool is present.

  Use this instead of checking `mcp_enabled? and map_size(mcp_tools) > 0` so
  that built-in tools are considered even when MCP is disabled.

  ## Examples

      iex> ToolPromptBuilder.any_tools_available?(%{})
      # true when memory is available, false otherwise

      iex> ToolPromptBuilder.any_tools_available?(%{"read_file" => %{...}})
      true

  """
  @spec any_tools_available?(map()) :: boolean()
  def any_tools_available?(mcp_tools) when is_map(mcp_tools) do
    Memory.available?() or map_size(mcp_tools) > 0
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  # Converts built-in tool modules into the MCP tools map format and merges
  # them with the provided MCP tools. MCP tools win on name collision.
  defp merge_with_builtin_tools(mcp_tools) do
    if Memory.available?() do
      builtin =
        BuiltinRegistry.list_tools()
        |> Enum.map(fn tool_module ->
          {tool_module.name(),
           %{
             description: tool_module.description(),
             schema: tool_module.parameters_schema(),
             requires_approval: false
           }}
        end)
        |> Map.new()

      # MCP tools take precedence over built-ins on name collision
      Map.merge(builtin, mcp_tools)
    else
      mcp_tools
    end
  end
end

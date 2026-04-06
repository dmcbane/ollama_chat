defmodule OllamaChat.BuiltinTools.Registry do
  @moduledoc """
  Discovers and manages all available built-in tools.

  Built-in tools execute in-process (as opposed to MCP tools that execute
  via external server processes). This registry provides lookup and schema
  generation for all registered built-in tools.

  ## Adding a New Built-in Tool

  1. Implement the `OllamaChat.BuiltinTool` behaviour
  2. Add the module to the `@tools` list below
  """

  alias OllamaChat.BuiltinTools.Memory

  @tools [
    Memory.Save,
    Memory.Search,
    Memory.Update,
    Memory.Delete,
    Memory.List
  ]

  @doc """
  Returns the list of all registered built-in tool modules.
  """
  @spec list_tools() :: [module()]
  def list_tools, do: @tools

  @doc """
  Looks up a built-in tool module by its string name.

  Returns the tool module if found, or `nil` if not registered.

  ## Examples

      iex> Registry.get_tool("memory_save")
      OllamaChat.BuiltinTools.Memory.Save

      iex> Registry.get_tool("unknown_tool")
      nil

  """
  @spec get_tool(String.t()) :: module() | nil
  def get_tool(name) when is_binary(name) do
    Enum.find(@tools, fn tool -> tool.name() == name end)
  end

  @doc """
  Returns `true` if the given tool name belongs to a registered built-in tool.

  ## Examples

      iex> Registry.builtin_tool?("memory_save")
      true

      iex> Registry.builtin_tool?("read_file")
      false

  """
  @spec builtin_tool?(String.t()) :: boolean()
  def builtin_tool?(name) when is_binary(name) do
    get_tool(name) != nil
  end

  @doc """
  Returns JSON-schema-compatible tool descriptions for all built-in tools.

  Each map contains `"name"`, `"description"`, and `"parameters"` keys,
  matching the format expected by `MCPPromptBuilder`.

  ## Examples

      iex> schemas = Registry.tool_schemas()
      iex> Enum.any?(schemas, fn s -> s["name"] == "memory_save" end)
      true

  """
  @spec tool_schemas() :: [map()]
  def tool_schemas do
    Enum.map(@tools, fn tool ->
      %{
        "name" => tool.name(),
        "description" => tool.description(),
        "parameters" => tool.parameters_schema()
      }
    end)
  end
end

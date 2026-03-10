defmodule OllamaChat.MCPRegistry do
  @moduledoc """
  Registry and cache for MCP tools and their metadata.
  Provides fast lookups without hitting MCP servers.

  This module acts as a centralized registry for all discovered MCP tools,
  allowing the application to quickly check tool availability and metadata
  without making repeated calls to MCP servers.
  """

  use Agent
  require Logger

  @type tool_name :: String.t()
  @type tool_info :: %{
          server: atom(),
          name: String.t(),
          description: String.t(),
          schema: map(),
          requires_approval: boolean()
        }

  @doc """
  Starts the MCP registry.
  """
  def start_link(_opts) do
    Agent.start_link(fn -> %{tools: %{}, last_update: nil} end, name: __MODULE__)
  end

  @doc """
  Registers a map of tools in the registry.

  ## Parameters

    - tools: A map of tool names to tool information

  ## Examples

      iex> MCPRegistry.register_tools(%{
      ...>   "read_file" => %{
      ...>     server: :filesystem,
      ...>     name: "read_file",
      ...>     description: "Read a file",
      ...>     schema: %{},
      ...>     requires_approval: false
      ...>   }
      ...> })
      :ok

  """
  @spec register_tools(map()) :: :ok
  def register_tools(tools) when is_map(tools) do
    Logger.debug("Registering #{map_size(tools)} MCP tools in registry")

    Agent.update(__MODULE__, fn state ->
      %{state | tools: tools, last_update: DateTime.utc_now()}
    end)
  end

  @doc """
  Retrieves information about a specific tool.

  Returns `nil` if the tool is not found.

  ## Examples

      iex> MCPRegistry.get_tool("read_file")
      %{server: :filesystem, name: "read_file", ...}

      iex> MCPRegistry.get_tool("nonexistent")
      nil

  """
  @spec get_tool(tool_name()) :: tool_info() | nil
  def get_tool(tool_name) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.tools, tool_name)
    end)
  end

  @doc """
  Returns all registered tools.

  ## Examples

      iex> MCPRegistry.list_all_tools()
      %{
        "read_file" => %{server: :filesystem, ...},
        "get_current_time" => %{server: :time, ...}
      }

  """
  @spec list_all_tools() :: map()
  def list_all_tools do
    Agent.get(__MODULE__, fn state ->
      state.tools
    end)
  end

  @doc """
  Checks if a tool exists in the registry.

  ## Examples

      iex> MCPRegistry.tool_exists?("read_file")
      true

      iex> MCPRegistry.tool_exists?("nonexistent")
      false

  """
  @spec tool_exists?(tool_name()) :: boolean()
  def tool_exists?(tool_name) do
    Agent.get(__MODULE__, fn state ->
      Map.has_key?(state.tools, tool_name)
    end)
  end

  @doc """
  Returns when the registry was last updated.

  Returns `nil` if the registry has never been updated.

  ## Examples

      iex> MCPRegistry.last_update()
      ~U[2026-02-27 18:30:00Z]

  """
  @spec last_update() :: DateTime.t() | nil
  def last_update do
    Agent.get(__MODULE__, fn state ->
      state.last_update
    end)
  end

  @doc """
  Returns the count of registered tools.

  ## Examples

      iex> MCPRegistry.count()
      5

  """
  @spec count() :: non_neg_integer()
  def count do
    Agent.get(__MODULE__, fn state ->
      map_size(state.tools)
    end)
  end

  @doc """
  Clears all registered tools from the registry.

  Primarily used for testing.

  ## Examples

      iex> MCPRegistry.clear()
      :ok

  """
  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn state ->
      %{state | tools: %{}, last_update: nil}
    end)
  end

  @doc """
  Gets tools by server name.

  ## Examples

      iex> MCPRegistry.get_tools_by_server(:filesystem)
      [
        %{name: "read_file", ...},
        %{name: "write_file", ...}
      ]

  """
  @spec get_tools_by_server(atom()) :: list(tool_info())
  def get_tools_by_server(server_name) do
    Agent.get(__MODULE__, fn state ->
      state.tools
      |> Enum.filter(fn {_name, info} -> info.server == server_name end)
      |> Enum.map(fn {_name, info} -> info end)
    end)
  end

  @doc """
  Returns a summary of the registry state.

  ## Examples

      iex> MCPRegistry.summary()
      %{
        total_tools: 5,
        servers: [:filesystem, :time],
        last_update: ~U[2026-02-27 18:30:00Z]
      }

  """
  @spec summary() :: map()
  def summary do
    Agent.get(__MODULE__, fn state ->
      servers =
        state.tools
        |> Enum.map(fn {_name, info} -> info.server end)
        |> Enum.uniq()
        |> Enum.sort()

      %{
        total_tools: map_size(state.tools),
        servers: servers,
        last_update: state.last_update
      }
    end)
  end
end

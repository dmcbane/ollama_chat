defmodule OllamaChat.MCPClient do
  @moduledoc """
  Manages MCP server connections and tool execution.

  This module is responsible for:
  - Starting and supervising MCP server connections
  - Discovering available tools from all connected servers
  - Executing tool calls with proper error handling
  - Health monitoring and automatic reconnection
  """

  use GenServer
  require Logger

  alias ExMCP.Client

  @type server_name :: atom()
  @type tool_name :: String.t()
  @type tool_args :: map()
  @type tool_result :: {:ok, list()} | {:error, term()}

  defmodule State do
    @moduledoc false
    defstruct clients: %{},
              tools: %{},
              last_discovery: nil,
              # 5 minutes
              discovery_interval: 300_000
  end

  # Client API

  @doc """
  Starts the MCP client manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists all available tools from all connected MCP servers.
  Returns a map of tool names to their metadata.
  """
  @spec list_tools() :: {:ok, map()} | {:error, term()}
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc """
  Executes a tool call on the appropriate MCP server.
  """
  @spec call_tool(tool_name(), tool_args()) :: tool_result()
  def call_tool(tool_name, args) do
    GenServer.call(__MODULE__, {:call_tool, tool_name, args}, 30_000)
  end

  @doc """
  Returns the health status of all MCP servers.
  """
  @spec health_status() :: map()
  def health_status do
    GenServer.call(__MODULE__, :health_status)
  end

  @doc """
  Forces a rediscovery of tools from all servers.
  """
  @spec refresh_tools() :: :ok
  def refresh_tools do
    GenServer.cast(__MODULE__, :refresh_tools)
  end

  @doc """
  Returns whether MCP is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:ollama_chat, :mcp_enabled, false)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    if mcp_enabled?() do
      Logger.info("Starting MCP client manager")
      send(self(), :start_servers)
      {:ok, %State{}}
    else
      Logger.info("MCP client disabled")
      {:ok, %State{}}
    end
  end

  @impl true
  def handle_info(:start_servers, state) do
    servers = Application.get_env(:ollama_chat, :mcp_servers, [])

    clients =
      servers
      |> Enum.filter(& &1.enabled)
      |> Enum.reduce(%{}, fn server_config, acc ->
        case start_mcp_server(server_config) do
          {:ok, client_pid} ->
            Logger.info("Started MCP server: #{server_config.display_name}")

            Map.put(acc, server_config.name, %{
              pid: client_pid,
              config: server_config,
              status: :connected,
              last_health_check: DateTime.utc_now()
            })

          {:error, reason} ->
            Logger.error(
              "Failed to start MCP server #{server_config.display_name}: #{inspect(reason)}"
            )

            acc
        end
      end)

    # Schedule tool discovery
    _ref =
      if map_size(clients) > 0 do
        Process.send_after(self(), :discover_tools, 1000)
      end

    {:noreply, %{state | clients: clients}}
  end

  @impl true
  def handle_info(:discover_tools, state) do
    tools = discover_all_tools(state.clients)
    Logger.info("Discovered #{map_size(tools)} MCP tools")

    # Update the registry
    OllamaChat.MCPRegistry.register_tools(tools)

    # Schedule next discovery
    _ref =
      if state.discovery_interval > 0 do
        Process.send_after(self(), :discover_tools, state.discovery_interval)
      end

    {:noreply, %{state | tools: tools, last_discovery: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, {:ok, state.tools}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, args}, _from, state) do
    result = execute_tool(tool_name, args, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:health_status, _from, state) do
    status =
      state.clients
      |> Enum.map(fn {name, client_info} ->
        {name,
         %{
           status: client_info.status,
           display_name: client_info.config.display_name,
           last_check: client_info.last_health_check
         }}
      end)
      |> Enum.into(%{})

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:refresh_tools, state) do
    send(self(), :discover_tools)
    {:noreply, state}
  end

  # Private Functions

  defp start_mcp_server(config) do
    Client.start_link(
      transport: :stdio,
      command: [config.command | config.args]
    )
  end

  @dialyzer {:nowarn_function, discover_all_tools: 1}
  defp discover_all_tools(clients) do
    clients
    |> Enum.flat_map(fn {server_name, client_info} ->
      case Client.list_tools(client_info.pid) do
        {:ok, %ExMCP.Response{tools: tools}} when is_list(tools) ->
          tools
          |> Enum.map(fn tool ->
            tool_name = tool[:name] || tool["name"]
            tool_desc = tool[:description] || tool["description"] || ""
            tool_schema = tool[:inputSchema] || tool["inputSchema"] || %{}

            {tool_name,
             %{
               server: server_name,
               name: tool_name,
               description: tool_desc,
               schema: tool_schema,
               requires_approval: requires_approval?(client_info.config, tool_name)
             }}
          end)

        {:ok, _other} ->
          Logger.warning("Unexpected response format from #{server_name}")
          []

        {:error, reason} ->
          Logger.warning("Failed to list tools from #{server_name}: #{inspect(reason)}")
          []

        _ ->
          []
      end
    end)
    |> Enum.into(%{})
  end

  defp execute_tool(tool_name, args, state) do
    case Map.get(state.tools, tool_name) do
      nil ->
        Logger.warning("Tool not found: #{tool_name}")
        {:error, "Tool not found: #{tool_name}"}

      tool_info ->
        client_info = Map.get(state.clients, tool_info.server)

        Logger.info("Executing tool: #{tool_name} on server: #{tool_info.server}")

        case Client.call_tool(client_info.pid, tool_name, args) do
          {:ok, result} ->
            Logger.debug("Tool #{tool_name} executed successfully")
            {:ok, result}

          {:error, reason} ->
            Logger.error("Tool execution failed for #{tool_name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @dialyzer {:nowarn_function, requires_approval?: 2}
  defp requires_approval?(server_config, tool_name) do
    server_config.requires_approval ||
      tool_name in Map.get(server_config, :dangerous_tools, [])
  end

  defp mcp_enabled? do
    Application.get_env(:ollama_chat, :mcp_enabled, false)
  end
end

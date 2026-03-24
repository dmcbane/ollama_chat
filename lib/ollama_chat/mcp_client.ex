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
              discovery_interval: 300_000,
              restart_timers: %{}
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
  Returns detailed server information including restart counts.
  """
  @spec server_info() :: map()
  def server_info do
    GenServer.call(__MODULE__, :server_info)
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
      # Trap exits so we can handle crashed MCP clients
      Process.flag(:trap_exit, true)
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
            # Monitor the client process
            Process.link(client_pid)

            Map.put(acc, server_config.name, %{
              pid: client_pid,
              config: server_config,
              status: :connected,
              last_health_check: DateTime.utc_now(),
              restart_count: 0
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
  def handle_info({:EXIT, pid, reason}, state) do
    # Find which server crashed
    case find_server_by_pid(state.clients, pid) do
      nil ->
        Logger.warning("Received EXIT from unknown process #{inspect(pid)}: #{inspect(reason)}")
        {:noreply, state}

      {server_name, client_info} ->
        # Log detailed crash information
        reason_str = format_crash_reason(reason)

        Logger.warning(
          "MCP server crashed: #{client_info.config.display_name} (#{server_name}) - #{reason_str}"
        )

        # Remove the crashed client
        new_clients = Map.delete(state.clients, server_name)

        # Schedule restart with exponential backoff
        restart_count = client_info.restart_count
        backoff_ms = calculate_backoff(restart_count)

        if restart_count < 10 do
          Logger.info(
            "Will restart #{client_info.config.display_name} in #{div(backoff_ms, 1000)}s (attempt #{restart_count + 1}/10)"
          )
        else
          Logger.error(
            "#{client_info.config.display_name} has crashed #{restart_count} times. Last attempt coming up."
          )
        end

        timer_ref = Process.send_after(self(), {:restart_server, server_name}, backoff_ms)

        new_timers = Map.put(state.restart_timers, server_name, timer_ref)

        {:noreply, %{state | clients: new_clients, restart_timers: new_timers}}
    end
  end

  @impl true
  def handle_info({:restart_server, server_name}, state) do
    # Find the server config in the original list
    servers = Application.get_env(:ollama_chat, :mcp_servers, [])

    case Enum.find(servers, fn s -> s.name == server_name end) do
      nil ->
        Logger.warning("Cannot restart #{server_name}: config not found")
        {:noreply, state}

      server_config ->
        # Get the previous restart count if it exists
        old_client = get_in(state.clients, [server_name])
        restart_count = if old_client, do: old_client.restart_count + 1, else: 0

        # Don't restart if too many failures
        if restart_count > 10 do
          Logger.error(
            "MCP server #{server_config.display_name} failed too many times (#{restart_count} attempts). Giving up."
          )

          {:noreply, state}
        else
          case start_mcp_server(server_config) do
            {:ok, client_pid} ->
              Logger.info(
                "Restarted MCP server: #{server_config.display_name} (attempt #{restart_count + 1})"
              )

              Process.link(client_pid)

              new_client = %{
                pid: client_pid,
                config: server_config,
                status: :connected,
                last_health_check: DateTime.utc_now(),
                restart_count: restart_count
              }

              new_clients = Map.put(state.clients, server_name, new_client)
              new_timers = Map.delete(state.restart_timers, server_name)

              # Rediscover tools after restart
              send(self(), :discover_tools)

              {:noreply, %{state | clients: new_clients, restart_timers: new_timers}}

            {:error, reason} ->
              Logger.error(
                "Failed to restart MCP server #{server_config.display_name}: #{inspect(reason)}"
              )

              # Schedule another retry
              backoff_ms = calculate_backoff(restart_count + 1)
              timer_ref = Process.send_after(self(), {:restart_server, server_name}, backoff_ms)

              new_timers = Map.put(state.restart_timers, server_name, timer_ref)

              {:noreply, %{state | restart_timers: new_timers}}
          end
        end
    end
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
  def handle_call(:server_info, _from, state) do
    info =
      state.clients
      |> Enum.map(fn {name, client_info} ->
        {name,
         %{
           status: client_info.status,
           display_name: client_info.config.display_name,
           last_check: client_info.last_health_check,
           restart_count: client_info.restart_count,
           pid: inspect(client_info.pid)
         }}
      end)
      |> Enum.into(%{})

    # Add info about servers scheduled for restart
    restart_info =
      state.restart_timers
      |> Enum.map(fn {name, _ref} ->
        {name, %{status: :restarting}}
      end)
      |> Enum.into(%{})

    combined = Map.merge(restart_info, info)

    {:reply, combined, state}
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
  rescue
    error ->
      Logger.error("Exception starting MCP server #{config.display_name}: #{inspect(error)}")
      {:error, error}
  catch
    :exit, reason ->
      Logger.error("Exit starting MCP server #{config.display_name}: #{inspect(reason)}")
      {:error, reason}
  end

  defp find_server_by_pid(clients, pid) do
    Enum.find(clients, fn {_name, info} -> info.pid == pid end)
  end

  defp calculate_backoff(restart_count) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, max 60s
    base_delay = 1000
    max_delay = 60_000
    delay = base_delay * :math.pow(2, restart_count)
    min(trunc(delay), max_delay)
  end

  defp format_crash_reason({:transport_connect_failed, msg}) do
    "Transport connection failed: #{msg}"
  end

  defp format_crash_reason(:normal) do
    "Normal shutdown"
  end

  defp format_crash_reason(:shutdown) do
    "Shutdown"
  end

  defp format_crash_reason({:shutdown, reason}) do
    "Shutdown: #{inspect(reason)}"
  end

  defp format_crash_reason(reason) when is_binary(reason) do
    reason
  end

  defp format_crash_reason(reason) do
    inspect(reason)
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
        case Map.get(state.clients, tool_info.server) do
          nil ->
            Logger.error("MCP server #{tool_info.server} not connected for tool #{tool_name}")
            {:error, "MCP server not available (may be restarting)"}

          client_info ->
            Logger.info("Executing tool: #{tool_name} on server: #{tool_info.server}")

            try do
              case Client.call_tool(client_info.pid, tool_name, args) do
                {:ok, result} ->
                  Logger.debug("Tool #{tool_name} executed successfully")
                  {:ok, result}

                {:error, reason} ->
                  Logger.error("Tool execution failed for #{tool_name}: #{inspect(reason)}")
                  {:error, reason}
              end
            catch
              :exit, reason ->
                Logger.error(
                  "MCP client crashed during tool execution: #{tool_name} - #{inspect(reason)}"
                )

                {:error, "MCP server crashed during execution"}
            end
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

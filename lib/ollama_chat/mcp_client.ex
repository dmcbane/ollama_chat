defmodule OllamaChat.MCPClient do
  @moduledoc """
  Manages MCP server connections and tool execution.

  This module is responsible for:
  - Starting and supervising MCP server connections
  - Discovering available tools from all connected servers
  - Executing tool calls with proper error handling
  - Health monitoring and automatic reconnection
  - Dynamic server management (add, remove, update, toggle)
  - Persisting server configurations via `OllamaChat.MCPConfig`
  """

  use GenServer
  require Logger

  alias ExMCP.Client
  alias OllamaChat.MCPConfig

  @type server_name :: atom()
  @type tool_name :: String.t()
  @type tool_args :: map()
  @type tool_result :: {:ok, list()} | {:error, term()}

  defmodule State do
    @moduledoc false
    defstruct clients: %{},
              tools: %{},
              server_configs: [],
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

  @doc """
  Adds a new MCP server at runtime.
  The config is validated, persisted to the config file, and the server is started if enabled.
  """
  @spec add_server(map()) :: :ok | {:error, term()}
  def add_server(config) do
    GenServer.call(__MODULE__, {:add_server, config}, 15_000)
  end

  @doc """
  Removes an MCP server by name, stopping it if running.
  """
  @spec remove_server(server_name()) :: :ok | {:error, term()}
  def remove_server(name) do
    GenServer.call(__MODULE__, {:remove_server, name}, 15_000)
  end

  @doc """
  Updates an existing MCP server's configuration.
  Stops the old server and starts a new one with the updated config.
  """
  @spec update_server(server_name(), map()) :: :ok | {:error, term()}
  def update_server(name, config) do
    GenServer.call(__MODULE__, {:update_server, name, config}, 15_000)
  end

  @doc """
  Toggles a server's enabled state. Starts or stops the server accordingly.
  """
  @spec toggle_server(server_name(), boolean()) :: :ok | {:error, term()}
  def toggle_server(name, enabled) do
    GenServer.call(__MODULE__, {:toggle_server, name, enabled}, 15_000)
  end

  @doc """
  Returns the current list of all server configurations.
  """
  @spec list_server_configs() :: [map()]
  def list_server_configs do
    GenServer.call(__MODULE__, :list_server_configs)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Always trap exits so dynamic server management works
    # even when MCP starts disabled (servers can be added at runtime)
    Process.flag(:trap_exit, true)

    if mcp_enabled?() do
      Logger.info("Starting MCP client manager")
      configs = MCPConfig.load_with_defaults()
      send(self(), :start_servers)
      {:ok, %State{server_configs: configs}}
    else
      Logger.info("MCP client disabled")
      {:ok, %State{}}
    end
  end

  @impl true
  def handle_info(:start_servers, state) do
    servers = state.server_configs

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
    # Find the server config from our stored configs
    case Enum.find(state.server_configs, fn s -> s.name == server_name end) do
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
  def handle_call({:add_server, config}, _from, state) do
    case MCPConfig.validate_server_config(config) do
      {:ok, validated} ->
        if Enum.any?(state.server_configs, fn s -> s.name == validated.name end) do
          {:reply, {:error, "Server with name #{validated.name} already exists"}, state}
        else
          new_configs = state.server_configs ++ [validated]
          persist_configs(new_configs)
          state = %{state | server_configs: new_configs}
          state = maybe_start_server(state, validated)
          {:reply, :ok, state}
        end

      {:error, errors} ->
        {:reply, {:error, {:validation, errors}}, state}
    end
  end

  @impl true
  def handle_call({:remove_server, name}, _from, state) do
    name = to_server_name(name)

    if Enum.any?(state.server_configs, fn s -> s.name == name end) do
      # Stop the server if running
      state = stop_and_remove_client(state, name)

      # Remove from configs
      new_configs = Enum.reject(state.server_configs, fn s -> s.name == name end)
      persist_configs(new_configs)

      # Cancel any pending restart timers
      new_timers = cancel_and_remove_timer(state.restart_timers, name)

      # Remove tools belonging to this server
      new_tools = Map.reject(state.tools, fn {_tool_name, info} -> info.server == name end)
      OllamaChat.MCPRegistry.register_tools(new_tools)

      state = %{
        state
        | server_configs: new_configs,
          restart_timers: new_timers,
          tools: new_tools
      }

      {:reply, :ok, state}
    else
      {:reply, {:error, "Server #{name} not found"}, state}
    end
  end

  @impl true
  def handle_call({:update_server, name, config}, _from, state) do
    name = to_server_name(name)

    case MCPConfig.validate_server_config(config) do
      {:ok, validated} ->
        if Enum.any?(state.server_configs, fn s -> s.name == name end) do
          state = stop_and_remove_client(state, name)
          new_timers = cancel_and_remove_timer(state.restart_timers, name)
          new_configs = replace_config(state.server_configs, name, validated)
          persist_configs(new_configs)

          state = %{state | server_configs: new_configs, restart_timers: new_timers}
          state = maybe_start_server(state, validated)
          {:reply, :ok, state}
        else
          {:reply, {:error, "Server #{name} not found"}, state}
        end

      {:error, errors} ->
        {:reply, {:error, {:validation, errors}}, state}
    end
  end

  @impl true
  def handle_call({:toggle_server, name, enabled}, _from, state) do
    name = to_server_name(name)

    case Enum.find(state.server_configs, fn s -> s.name == name end) do
      nil ->
        {:reply, {:error, "Server #{name} not found"}, state}

      server_config ->
        updated_config = %{server_config | enabled: enabled}

        new_configs =
          Enum.map(state.server_configs, fn s ->
            if s.name == name, do: updated_config, else: s
          end)

        persist_configs(new_configs)

        state =
          cond do
            enabled and not Map.has_key?(state.clients, name) ->
              # Enable: start the server
              case start_mcp_server(updated_config) do
                {:ok, client_pid} ->
                  Logger.info("Enabled and started MCP server: #{updated_config.display_name}")

                  Process.link(client_pid)

                  client_info = %{
                    pid: client_pid,
                    config: updated_config,
                    status: :connected,
                    last_health_check: DateTime.utc_now(),
                    restart_count: 0
                  }

                  new_clients = Map.put(state.clients, name, client_info)
                  send(self(), :discover_tools)
                  %{state | clients: new_clients, server_configs: new_configs}

                {:error, reason} ->
                  Logger.error(
                    "Failed to start MCP server #{updated_config.display_name}: #{inspect(reason)}"
                  )

                  %{state | server_configs: new_configs}
              end

            not enabled and Map.has_key?(state.clients, name) ->
              # Disable: stop the server
              state = stop_and_remove_client(%{state | server_configs: new_configs}, name)
              new_timers = cancel_and_remove_timer(state.restart_timers, name)

              # Remove tools from this server
              new_tools =
                Map.reject(state.tools, fn {_t, info} -> info.server == name end)

              OllamaChat.MCPRegistry.register_tools(new_tools)
              %{state | restart_timers: new_timers, tools: new_tools}

            true ->
              # No state change needed (already in the desired state)
              %{state | server_configs: new_configs}
          end

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:list_server_configs, _from, state) do
    {:reply, state.server_configs, state}
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
            with :ok <- guard_root_path(tool_name, args, client_info.config) do
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
  end

  defp guard_root_path(_tool_name, _args, %{root_path: nil}), do: :ok
  defp guard_root_path(_tool_name, _args, %{root_path: ""}), do: :ok

  defp guard_root_path(tool_name, args, %{root_path: root_path}) do
    case OllamaChat.PathGuard.sanitize_args(args, root_path) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Tool #{tool_name} blocked by path guard: #{reason}")
        {:error, "Access denied: #{reason}"}
    end
  end

  defp guard_root_path(_tool_name, _args, _config), do: :ok

  @dialyzer {:nowarn_function, requires_approval?: 2}
  defp requires_approval?(server_config, tool_name) do
    server_config.requires_approval ||
      tool_name in Map.get(server_config, :dangerous_tools, [])
  end

  defp replace_config(configs, name, new_config) do
    Enum.map(configs, fn s -> if s.name == name, do: new_config, else: s end)
  end

  defp mcp_enabled? do
    Application.get_env(:ollama_chat, :mcp_enabled, false)
  end

  defp maybe_start_server(state, config) do
    if config.enabled do
      start_and_link_server(state, config)
    else
      state
    end
  end

  defp start_and_link_server(state, config) do
    case start_mcp_server(config) do
      {:ok, client_pid} ->
        Logger.info("Started MCP server: #{config.display_name}")
        Process.link(client_pid)

        client_info = %{
          pid: client_pid,
          config: config,
          status: :connected,
          last_health_check: DateTime.utc_now(),
          restart_count: 0
        }

        new_clients = Map.put(state.clients, config.name, client_info)
        send(self(), :discover_tools)
        %{state | clients: new_clients}

      {:error, reason} ->
        Logger.error("Failed to start MCP server #{config.display_name}: #{inspect(reason)}")

        state
    end
  end

  defp to_server_name(name) when is_atom(name), do: name
  defp to_server_name(name) when is_binary(name), do: String.to_atom(name)

  defp stop_and_remove_client(state, name) do
    case Map.get(state.clients, name) do
      nil ->
        state

      client_info ->
        # Unlink before stopping to avoid triggering our EXIT handler
        Process.unlink(client_info.pid)

        try do
          GenServer.stop(client_info.pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

        Logger.info("Stopped MCP server: #{client_info.config.display_name}")
        %{state | clients: Map.delete(state.clients, name)}
    end
  end

  defp cancel_and_remove_timer(timers, name) do
    case Map.get(timers, name) do
      nil ->
        timers

      ref ->
        Process.cancel_timer(ref)
        Map.delete(timers, name)
    end
  end

  defp persist_configs(configs) do
    case MCPConfig.save(configs) do
      :ok ->
        Logger.debug("Persisted MCP server configs")
        :ok

      {:error, reason} ->
        Logger.error("Failed to persist MCP server configs: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

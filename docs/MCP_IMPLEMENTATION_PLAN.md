# MCP Client Implementation Plan

**Project**: Ollama Chat  
**Feature**: Model Context Protocol (MCP) Client Integration  
**Date**: February 27, 2026  
**Status**: Planning  
**Library**: ex_mcp v0.8.x

## Executive Summary

This document outlines the implementation plan for integrating MCP (Model Context Protocol) client capabilities into Ollama Chat. This will transform the application from a pure conversational interface into an actionable AI assistant capable of interacting with external tools, services, and data sources.

### Goals
1. Enable LLMs to execute real-world tasks through MCP tools
2. Support multiple MCP servers (filesystem, web search, databases, etc.)
3. Maintain security with user approval workflows
4. Provide excellent UX with clear tool execution visibility
5. Build extensible architecture for future tool additions

### Success Metrics
- Successfully connect to and manage 3+ MCP servers
- Execute tool calls with <500ms overhead
- User approval workflow with <3 clicks
- Zero security incidents (proper sandboxing)
- 95%+ test coverage for MCP integration

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    User Interface (LiveView)             │
│  • Chat messages                                         │
│  • Tool call indicators                                  │
│  • Approval prompts                                      │
│  • MCP settings panel                                    │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│              ChatLive (LiveView)                         │
│  • Message flow coordination                             │
│  • Tool call detection                                   │
│  • Result injection                                      │
└────────────────┬────────────────────────────────────────┘
                 │
                 ├─────────────────┬───────────────────────┐
                 ▼                 ▼                       ▼
┌─────────────────────┐  ┌──────────────────┐  ┌─────────────────┐
│   OllamaClient      │  │   MCPClient      │  │   MCPRegistry   │
│  (existing)         │  │  (new)           │  │   (new)         │
│                     │  │                  │  │                 │
│ • Stream chat       │  │ • Manage servers │  │ • Tool catalog  │
│ • Parse responses   │  │ • Execute tools  │  │ • Tool schemas  │
└─────────────────────┘  │ • Health checks  │  │ • Capabilities  │
                         └────────┬─────────┘  └─────────────────┘
                                  │
                                  ▼
                    ┌──────────────────────────┐
                    │   ExMCP.Client           │
                    │   (ex_mcp library)       │
                    └────────┬─────────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
      ┌──────────────┐ ┌─────────────┐ ┌──────────────┐
      │ MCP Server 1 │ │ MCP Server 2│ │ MCP Server 3 │
      │ (filesystem) │ │ (search)    │ │ (database)   │
      └──────────────┘ └─────────────┘ └──────────────┘
```

---

## Phase 1: Foundation (Week 1)

### Goals
- Add ex_mcp dependency
- Create basic MCP client infrastructure
- Configure and start one test MCP server
- Establish supervision tree structure

### Tasks

#### 1.1 Add Dependencies
**File**: `mix.exs`

```elixir
defp deps do
  [
    # ... existing deps
    {:ex_mcp, "~> 0.8.0"}
  ]
end
```

Run: `mix deps.get && mix deps.compile`

#### 1.2 Create Configuration
**File**: `config/config.exs`

```elixir
# MCP Server Configuration
config :ollama_chat, :mcp_servers, [
  %{
    name: :filesystem,
    display_name: "File System",
    description: "Read and write files",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", System.get_env("MCP_FILESYSTEM_ROOT", "/tmp/mcp")],
    enabled: true,
    requires_approval: true,
    dangerous_tools: ["write_file", "delete_file"]
  }
]

config :ollama_chat, :mcp_enabled, true
```

**File**: `config/dev.exs`

```elixir
# Development-specific MCP settings
config :ollama_chat, :mcp_servers, [
  %{
    name: :filesystem,
    display_name: "File System (Dev)",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", Path.expand("./tmp/mcp_workspace")],
    enabled: true,
    requires_approval: false  # Auto-approve in dev
  }
]
```

**File**: `config/test.exs`

```elixir
# Disable MCP in tests by default
config :ollama_chat, :mcp_enabled, false
config :ollama_chat, :mcp_servers, []
```

#### 1.3 Create MCP Client Module
**File**: `lib/ollama_chat/mcp_client.ex`

```elixir
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
              discovery_interval: 300_000  # 5 minutes
  end

  # Client API

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
            Logger.error("Failed to start MCP server #{server_config.display_name}: #{inspect(reason)}")
            acc
        end
      end)
    
    # Schedule tool discovery
    Process.send_after(self(), :discover_tools, 1000)
    
    {:noreply, %{state | clients: clients}}
  end

  @impl true
  def handle_info(:discover_tools, state) do
    tools = discover_all_tools(state.clients)
    Logger.info("Discovered #{map_size(tools)} MCP tools")
    
    # Schedule next discovery
    Process.send_after(self(), :discover_tools, state.discovery_interval)
    
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
        {name, %{
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

  defp discover_all_tools(clients) do
    clients
    |> Enum.flat_map(fn {server_name, client_info} ->
      case Client.list_tools(client_info.pid) do
        {:ok, tools} ->
          tools
          |> Enum.map(fn tool ->
            {tool["name"], %{
              server: server_name,
              name: tool["name"],
              description: tool["description"],
              schema: tool["inputSchema"],
              requires_approval: requires_approval?(client_info.config, tool["name"])
            }}
          end)
        
        {:error, reason} ->
          Logger.warning("Failed to list tools from #{server_name}: #{inspect(reason)}")
          []
      end
    end)
    |> Enum.into(%{})
  end

  defp execute_tool(tool_name, args, state) do
    case Map.get(state.tools, tool_name) do
      nil ->
        {:error, "Tool not found: #{tool_name}"}
      
      tool_info ->
        client_info = Map.get(state.clients, tool_info.server)
        
        case Client.call_tool(client_info.pid, tool_name, args) do
          {:ok, result} ->
            {:ok, result}
          
          {:error, reason} ->
            Logger.error("Tool execution failed for #{tool_name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp requires_approval?(server_config, tool_name) do
    server_config.requires_approval || 
      tool_name in Map.get(server_config, :dangerous_tools, [])
  end

  defp mcp_enabled? do
    Application.get_env(:ollama_chat, :mcp_enabled, false)
  end
end
```

#### 1.4 Create MCP Registry Module
**File**: `lib/ollama_chat/mcp_registry.ex`

```elixir
defmodule OllamaChat.MCPRegistry do
  @moduledoc """
  Registry and cache for MCP tools and their metadata.
  Provides fast lookups without hitting MCP servers.
  """

  use Agent
  require Logger

  def start_link(_opts) do
    Agent.start_link(fn -> %{tools: %{}, last_update: nil} end, name: __MODULE__)
  end

  def register_tools(tools) when is_map(tools) do
    Agent.update(__MODULE__, fn state ->
      %{state | tools: tools, last_update: DateTime.utc_now()}
    end)
  end

  def get_tool(tool_name) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.tools, tool_name)
    end)
  end

  def list_all_tools do
    Agent.get(__MODULE__, fn state ->
      state.tools
    end)
  end

  def tool_exists?(tool_name) do
    Agent.get(__MODULE__, fn state ->
      Map.has_key?(state.tools, tool_name)
    end)
  end
end
```

#### 1.5 Update Application Supervision Tree
**File**: `lib/ollama_chat/application.ex`

```elixir
def start(_type, _args) do
  children = [
    OllamaChatWeb.Telemetry,
    {DNSCluster, query: Application.get_env(:ollama_chat, :dns_cluster_query) || :ignore},
    {Phoenix.PubSub, name: OllamaChat.PubSub},
    {Finch, name: OllamaChat.Finch},
    # Add MCP support
    OllamaChat.MCPRegistry,
    OllamaChat.MCPClient,
    OllamaChatWeb.Endpoint
  ]

  opts = [strategy: :one_for_one, name: OllamaChat.Supervisor]
  Supervisor.start_link(children, opts)
end
```

#### 1.6 Create Basic Test
**File**: `test/ollama_chat/mcp_client_test.exs`

```elixir
defmodule OllamaChat.MCPClientTest do
  use ExUnit.Case, async: false

  alias OllamaChat.MCPClient

  describe "when MCP is disabled" do
    test "client starts but returns empty tools" do
      assert {:ok, tools} = MCPClient.list_tools()
      assert tools == %{}
    end
  end

  # Integration tests will be added in Phase 2
end
```

---

## Phase 2: Ollama Function Calling Integration (Week 2)

### Goals
- Implement tool call detection from Ollama responses
- Create prompt engineering for tool calls
- Build tool call → MCP execution pipeline
- Handle tool results and continue conversation

### Challenge: Ollama Function Calling

Ollama may not have native function calling like OpenAI/Anthropic. We need to handle this gracefully.

#### Strategy 1: Structured Prompting (Primary)

Use system prompts to teach the model about available tools and response format.

**File**: `lib/ollama_chat/mcp_prompt_builder.ex`

```elixir
defmodule OllamaChat.MCPPromptBuilder do
  @moduledoc """
  Builds system prompts that teach LLMs to use MCP tools.
  """

  def build_tool_aware_system_prompt(tools) do
    """
    You are an AI assistant with access to the following tools:

    #{format_tools(tools)}

    When you need to use a tool, respond ONLY with a JSON object in this exact format:
    {"tool_call": {"name": "tool_name", "arguments": {"arg1": "value1"}}}

    After receiving tool results, continue the conversation naturally.
    If you don't need any tools, respond normally.
    """
  end

  defp format_tools(tools) do
    tools
    |> Enum.map(fn {name, info} ->
      """
      - #{name}: #{info.description}
        Arguments: #{format_schema(info.schema)}
      """
    end)
    |> Enum.join("\n")
  end

  defp format_schema(schema) do
    schema
    |> Map.get("properties", %{})
    |> Enum.map(fn {key, value} ->
      type = Map.get(value, "type", "string")
      desc = Map.get(value, "description", "")
      "#{key} (#{type}): #{desc}"
    end)
    |> Enum.join(", ")
  end
end
```

#### Strategy 2: Response Parser

**File**: `lib/ollama_chat/mcp_response_parser.ex`

```elixir
defmodule OllamaChat.MCPResponseParser do
  @moduledoc """
  Parses LLM responses to detect and extract tool calls.
  """

  @doc """
  Attempts to parse a tool call from the response.
  Returns {:tool_call, name, args} or :no_tool_call
  """
  def parse_response(response_text) do
    # Try JSON parsing first
    with {:ok, parsed} <- Jason.decode(response_text),
         %{"tool_call" => %{"name" => name, "arguments" => args}} <- parsed do
      {:tool_call, name, args}
    else
      _ ->
        # Fallback: try to find tool call patterns in text
        parse_text_pattern(response_text)
    end
  end

  defp parse_text_pattern(text) do
    # Look for patterns like: [TOOL_CALL: tool_name {args}]
    case Regex.run(~r/\[TOOL_CALL:\s*(\w+)\s+({.*?})\]/s, text) do
      [_, name, args_json] ->
        case Jason.decode(args_json) do
          {:ok, args} -> {:tool_call, name, args}
          _ -> :no_tool_call
        end
      
      _ ->
        :no_tool_call
    end
  end

  @doc """
  Removes tool call JSON from response text for display.
  """
  def strip_tool_call(response_text) do
    response_text
    |> String.replace(~r/\{"tool_call".*?\}/s, "")
    |> String.trim()
  end
end
```

### Tasks

#### 2.1 Extend ChatLive for Tool Calls
**File**: `lib/ollama_chat_web/live/chat_live.ex`

Add to assigns:
```elixir
:mcp_enabled? => Application.get_env(:ollama_chat, :mcp_enabled, false),
:mcp_tools => %{},
:pending_approval => nil,
:tool_calls => []
```

Add to mount:
```elixir
socket =
  if socket.assigns.mcp_enabled? do
    case OllamaChat.MCPClient.list_tools() do
      {:ok, tools} -> assign(socket, :mcp_tools, tools)
      _ -> socket
    end
  else
    socket
  end
```

#### 2.2 Tool Call Detection in Stream Handler
**File**: `lib/ollama_chat_web/live/chat_live.ex` (modify `handle_info({:stream_chunk}`)

```elixir
def handle_info({:stream_chunk, message_id, content}, socket) do
  current = socket.assigns.streaming_message
  new_content = current <> content

  # Check if we have a complete tool call
  case MCPResponseParser.parse_response(new_content) do
    {:tool_call, tool_name, args} ->
      # Stop streaming, execute tool
      socket = handle_tool_call(socket, message_id, tool_name, args)
      {:noreply, socket}
    
    :no_tool_call ->
      # Continue normal streaming
      updated_message = %{
        id: message_id,
        role: "assistant",
        content: new_content,
        html_content: nil,
        timestamp: DateTime.utc_now(),
        streaming: true
      }

      {:noreply,
       socket
       |> stream_insert(:messages, updated_message, at: -1)
       |> assign(:streaming_message, new_content)}
  end
end
```

#### 2.3 Tool Execution Handler

```elixir
defp handle_tool_call(socket, message_id, tool_name, args) do
  tool_info = Map.get(socket.assigns.mcp_tools, tool_name)
  
  if tool_info && tool_info.requires_approval do
    # Request user approval
    socket
    |> assign(:pending_approval, %{
      message_id: message_id,
      tool_name: tool_name,
      tool_info: tool_info,
      args: args
    })
    |> push_event("show_tool_approval", %{
      tool_name: tool_name,
      description: tool_info.description,
      args: args
    })
  else
    # Execute immediately
    execute_mcp_tool(socket, message_id, tool_name, args)
  end
end

defp execute_mcp_tool(socket, message_id, tool_name, args) do
  # Add tool call indicator message
  tool_call_message = %{
    id: "#{message_id}-tool-call",
    role: "tool_call",
    content: "Calling tool: #{tool_name}",
    tool_name: tool_name,
    args: args,
    timestamp: DateTime.utc_now()
  }
  
  socket = stream_insert(socket, :messages, tool_call_message, at: -1)
  
  # Execute tool in background
  parent = self()
  
  spawn(fn ->
    case OllamaChat.MCPClient.call_tool(tool_name, args) do
      {:ok, result} ->
        send(parent, {:tool_result, message_id, tool_name, result})
      
      {:error, reason} ->
        send(parent, {:tool_error, message_id, tool_name, reason})
    end
  end)
  
  assign(socket, :loading, true)
end
```

#### 2.4 Tool Result Handler

```elixir
def handle_info({:tool_result, message_id, tool_name, result}, socket) do
  # Add tool result message
  tool_result_message = %{
    id: "#{message_id}-tool-result",
    role: "tool_result",
    content: format_tool_result(result),
    tool_name: tool_name,
    timestamp: DateTime.utc_now()
  }
  
  socket = stream_insert(socket, :messages, tool_result_message, at: -1)
  
  # Continue LLM conversation with tool result
  socket = continue_with_tool_result(socket, tool_name, result)
  
  {:noreply, socket}
end

def handle_info({:tool_error, message_id, tool_name, reason}, socket) do
  error_message = %{
    id: "#{message_id}-tool-error",
    role: "tool_error",
    content: "Tool execution failed: #{inspect(reason)}",
    tool_name: tool_name,
    timestamp: DateTime.utc_now()
  }
  
  socket =
    socket
    |> stream_insert(:messages, error_message, at: -1)
    |> assign(:loading, false)
    |> assign(:error, "Tool execution failed")
  
  {:noreply, socket}
end

defp format_tool_result(result) do
  result
  |> Enum.map(fn
    %{"type" => "text", "text" => text} -> text
    %{"type" => "image"} = img -> "[Image: #{img["mimeType"]}]"
    other -> inspect(other)
  end)
  |> Enum.join("\n")
end

defp continue_with_tool_result(socket, tool_name, result) do
  # Add tool result to conversation context
  tool_result_text = format_tool_result(result)
  
  # Build new messages for LLM including tool result
  messages_for_api = build_messages_with_tool_result(
    socket.assigns.message_history,
    tool_name,
    tool_result_text
  )
  
  # Continue streaming with tool result context
  start_llm_stream(socket, messages_for_api)
end
```

---

## Phase 3: User Interface & Approval Workflow (Week 3)

### Goals
- Design and implement tool call UI indicators
- Build approval modal for dangerous operations
- Add MCP settings panel
- Show tool execution status

### Tasks

#### 3.1 Tool Call Message Component
**File**: `lib/ollama_chat_web/live/chat_live.ex` (in render function)

```heex
<%!-- Tool Call Indicator --%>
<%= if msg.role == "tool_call" do %>
  <div class="flex justify-center my-4">
    <div class="bg-blue-900/50 border border-blue-700 rounded-lg px-4 py-3 max-w-md">
      <div class="flex items-center gap-3">
        <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-blue-400 animate-pulse" />
        <div>
          <div class="text-sm font-medium text-blue-300">
            Calling tool: <%= msg.tool_name %>
          </div>
          <div class="text-xs text-blue-400 mt-1">
            <%= format_tool_args(msg.args) %>
          </div>
        </div>
      </div>
    </div>
  </div>
<% end %>

<%!-- Tool Result --%>
<%= if msg.role == "tool_result" do %>
  <div class="flex justify-center my-4">
    <div class="bg-green-900/50 border border-green-700 rounded-lg px-4 py-3 max-w-md">
      <div class="flex items-center gap-3">
        <.icon name="hero-check-circle" class="w-5 h-5 text-green-400" />
        <div>
          <div class="text-sm font-medium text-green-300">
            Tool completed: <%= msg.tool_name %>
          </div>
          <div class="text-xs text-green-400 mt-1 font-mono">
            <%= String.slice(msg.content, 0, 100) %><%= if String.length(msg.content) > 100, do: "..." %>
          </div>
        </div>
      </div>
    </div>
  </div>
<% end %>

<%!-- Tool Error --%>
<%= if msg.role == "tool_error" do %>
  <div class="flex justify-center my-4">
    <div class="bg-red-900/50 border border-red-700 rounded-lg px-4 py-3 max-w-md">
      <div class="flex items-center gap-3">
        <.icon name="hero-x-circle" class="w-5 h-5 text-red-400" />
        <div>
          <div class="text-sm font-medium text-red-300">
            Tool failed: <%= msg.tool_name %>
          </div>
          <div class="text-xs text-red-400 mt-1">
            <%= msg.content %>
          </div>
        </div>
      </div>
    </div>
  </div>
<% end %>
```

#### 3.2 Tool Approval Modal
**File**: `lib/ollama_chat_web/live/chat_live.ex`

```heex
<%!-- Tool Approval Modal --%>
<%= if @pending_approval do %>
  <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50" phx-click="cancel_tool_approval">
    <div class="bg-slate-800 border border-slate-700 rounded-lg p-6 max-w-lg w-full mx-4" phx-click-stop>
      <div class="flex items-center gap-3 mb-4">
        <.icon name="hero-shield-exclamation" class="w-8 h-8 text-yellow-400" />
        <h3 class="text-xl font-bold text-white">Tool Approval Required</h3>
      </div>
      
      <div class="space-y-3 mb-6">
        <div>
          <div class="text-sm font-medium text-gray-400">Tool</div>
          <div class="text-lg text-white"><%= @pending_approval.tool_name %></div>
        </div>
        
        <div>
          <div class="text-sm font-medium text-gray-400">Description</div>
          <div class="text-white"><%= @pending_approval.tool_info.description %></div>
        </div>
        
        <div>
          <div class="text-sm font-medium text-gray-400">Arguments</div>
          <pre class="text-sm text-gray-300 bg-slate-900 p-3 rounded mt-1 overflow-x-auto"><%= Jason.encode!(@pending_approval.args, pretty: true) %></pre>
        </div>
      </div>
      
      <div class="flex gap-3">
        <button
          phx-click="approve_tool"
          class="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 text-white font-medium rounded-lg transition-colors"
        >
          Approve
        </button>
        <button
          phx-click="cancel_tool_approval"
          class="flex-1 px-4 py-2 bg-red-600 hover:bg-red-700 text-white font-medium rounded-lg transition-colors"
        >
          Deny
        </button>
      </div>
    </div>
  </div>
<% end %>
```

#### 3.3 Approval Event Handlers

```elixir
def handle_event("approve_tool", _params, socket) do
  approval = socket.assigns.pending_approval
  
  socket =
    socket
    |> assign(:pending_approval, nil)
    |> execute_mcp_tool(
      approval.message_id,
      approval.tool_name,
      approval.args
    )
  
  {:noreply, socket}
end

def handle_event("cancel_tool_approval", _params, socket) do
  socket =
    socket
    |> assign(:pending_approval, nil)
    |> assign(:error, "Tool execution cancelled by user")
    |> assign(:loading, false)
  
  {:noreply, socket}
end
```

#### 3.4 MCP Settings Panel
**File**: `lib/ollama_chat_web/live/chat_live.ex`

```heex
<%!-- MCP Settings Section (in sidebar) --%>
<%= if @mcp_enabled? do %>
  <div class="mb-6">
    <button
      phx-click="toggle_mcp_settings"
      class="w-full flex items-center justify-between text-left py-2 px-3 rounded-lg hover:bg-slate-700 transition-colors"
    >
      <div class="flex items-center gap-2">
        <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-blue-400" />
        <span class="text-sm font-medium text-white">MCP Tools</span>
        <span class="text-xs text-gray-400">(<%= map_size(@mcp_tools) %>)</span>
      </div>
      <.icon name={if @show_mcp_settings, do: "hero-chevron-up", else: "hero-chevron-down"} class="w-4 h-4 text-gray-400" />
    </button>
    
    <%= if @show_mcp_settings do %>
      <div class="mt-2 space-y-2 pl-3">
        <%= for {name, info} <- @mcp_tools do %>
          <div class="text-xs p-2 bg-slate-800 rounded border border-slate-700">
            <div class="font-medium text-blue-300"><%= name %></div>
            <div class="text-gray-400 mt-1"><%= info.description %></div>
            <div class="flex items-center gap-2 mt-1">
              <span class="text-gray-500">Server: <%= info.server %></span>
              <%= if info.requires_approval do %>
                <span class="text-xs px-1.5 py-0.5 bg-yellow-900/50 text-yellow-300 rounded">Requires approval</span>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
  </div>
<% end %>
```

---

## Phase 4: Testing & Refinement (Week 4)

### Goals
- Comprehensive test coverage
- Integration tests with real MCP servers
- Performance optimization
- Security hardening
- Documentation

### Tasks

#### 4.1 Unit Tests
**File**: `test/ollama_chat/mcp_client_test.exs`

```elixir
defmodule OllamaChat.MCPClientTest do
  use ExUnit.Case, async: false

  alias OllamaChat.MCPClient

  @moduletag :mcp

  setup do
    # Start a mock MCP server
    start_supervised!({MCPClient, []})
    :ok
  end

  describe "list_tools/0" do
    test "returns available tools" do
      assert {:ok, tools} = MCPClient.list_tools()
      assert is_map(tools)
    end
  end

  describe "call_tool/2" do
    test "executes tool successfully" do
      # Mock or use test MCP server
      assert {:ok, result} = MCPClient.call_tool("test_tool", %{})
      assert is_list(result)
    end

    test "returns error for non-existent tool" do
      assert {:error, _} = MCPClient.call_tool("nonexistent", %{})
    end

    test "handles tool execution timeout" do
      # Test timeout handling
    end
  end

  describe "health_status/0" do
    test "returns server health information" do
      assert is_map(MCPClient.health_status())
    end
  end
end
```

#### 4.2 Integration Tests
**File**: `test/ollama_chat_web/live/chat_live_mcp_test.exs`

```elixir
defmodule OllamaChatWeb.ChatLiveMCPTest do
  use OllamaChatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :mcp_integration

  setup do
    # Ensure MCP servers are running
    :ok
  end

  test "displays MCP tools in settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    assert view |> element("button", "MCP Tools") |> render_click()
    assert has_element?(view, "[data-test='mcp-tool']")
  end

  test "executes tool call from LLM response", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    # Send message that should trigger tool call
    view
    |> form("#chat-form", message: "List files in the current directory")
    |> render_submit()
    
    # Should see tool call indicator
    assert_async(fn ->
      assert has_element?(view, "[data-role='tool_call']")
    end)
  end

  test "shows approval modal for dangerous tools", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    view
    |> form("#chat-form", message: "Delete all files")
    |> render_submit()
    
    # Should show approval modal
    assert has_element?(view, "button", "Approve")
  end
end
```

#### 4.3 Performance Tests
**File**: `test/ollama_chat/mcp_performance_test.exs`

```elixir
defmodule OllamaChat.MCPPerformanceTest do
  use ExUnit.Case

  @moduletag :performance

  alias OllamaChat.MCPClient

  test "tool discovery completes within time limit" do
    {time, {:ok, _tools}} = :timer.tc(fn ->
      MCPClient.list_tools()
    end)
    
    # Should complete within 100ms
    assert time < 100_000
  end

  test "tool execution overhead is minimal" do
    # Measure pure execution time vs MCP overhead
    {time, _} = :timer.tc(fn ->
      MCPClient.call_tool("simple_tool", %{})
    end)
    
    # Overhead should be < 50ms
    assert time < 50_000
  end
end
```

#### 4.4 Security Audit Checklist

**File**: `docs/MCP_SECURITY_AUDIT.md`

```markdown
# MCP Security Audit Checklist

## Command Injection
- [ ] MCP server commands properly escaped
- [ ] No user input in command strings
- [ ] Arguments validated before passing to servers

## Path Traversal
- [ ] File paths validated and sanitized
- [ ] Base directory restrictions enforced
- [ ] Symlinks handled safely

## Approval Workflow
- [ ] All dangerous tools require approval
- [ ] Approval UI clearly shows action details
- [ ] No way to bypass approval requirement

## Rate Limiting
- [ ] Tool calls rate-limited per user
- [ ] Protection against infinite loops
- [ ] Timeout on long-running tools

## Input Validation
- [ ] Tool arguments validated against schema
- [ ] JSON parsing errors handled gracefully
- [ ] Size limits on tool inputs/outputs

## Audit Logging
- [ ] All tool executions logged
- [ ] User approvals/denials logged
- [ ] Failed attempts logged
- [ ] Logs include timestamp and context
```

---

## Phase 5: Documentation & Deployment (Week 5)

### Tasks

#### 5.1 User Documentation
**File**: `docs/MCP_USER_GUIDE.md`

```markdown
# MCP Tools User Guide

## What are MCP Tools?

MCP (Model Context Protocol) tools allow the AI assistant to perform real-world tasks like reading files, searching the web, or querying databases.

## Available Tools

### Filesystem Tools
- **read_file**: Read contents of a file
- **write_file**: Write content to a file (requires approval)
- **list_directory**: List files in a directory
- **delete_file**: Delete a file (requires approval)

## How to Use Tools

Simply ask the assistant to perform a task naturally:

"Read the contents of config.json"
"Create a new file called notes.txt with this content..."
"List all Python files in the src directory"

The assistant will automatically use the appropriate tool.

## Approval System

Some tools require your approval before execution:
- Writing files
- Deleting files
- Executing commands
- Accessing sensitive data

When approval is needed:
1. A modal will appear showing the tool and arguments
2. Review the details carefully
3. Click "Approve" or "Deny"

## Configuring MCP

Access MCP settings from the sidebar:
- View available tools
- See which servers are connected
- Check tool descriptions and requirements
```

#### 5.2 Developer Documentation
**File**: `docs/MCP_DEVELOPER_GUIDE.md`

```markdown
# MCP Developer Guide

## Adding New MCP Servers

1. Add to configuration:
```elixir
config :ollama_chat, :mcp_servers, [
  %{
    name: :my_server,
    display_name: "My Server",
    description: "Does cool things",
    command: "npx",
    args: ["-y", "@my-org/mcp-server"],
    enabled: true,
    requires_approval: true,
    dangerous_tools: ["delete", "modify"]
  }
]
```

2. Server will auto-start with application
3. Tools will be discovered automatically

## Creating Custom MCP Servers

See `ex_mcp` documentation for creating Elixir MCP servers.

## Testing

Run MCP tests:
```bash
# Unit tests
mix test --only mcp

# Integration tests (requires servers)
mix test --only mcp_integration
```
```

#### 5.3 Deployment Checklist

```markdown
# MCP Deployment Checklist

## Pre-deployment
- [ ] All tests passing (unit + integration)
- [ ] Security audit completed
- [ ] Performance benchmarks met
- [ ] Documentation complete
- [ ] MCP servers configured for production
- [ ] Approval workflow tested

## Configuration
- [ ] Production MCP servers defined
- [ ] File paths restricted to safe directories
- [ ] Rate limits configured
- [ ] Logging enabled
- [ ] Monitoring alerts configured

## Post-deployment
- [ ] Monitor error rates
- [ ] Check tool execution times
- [ ] Verify approval workflow
- [ ] Review audit logs
- [ ] User feedback collection
```

---

## Risk Mitigation

### Risk 1: Ollama Doesn't Support Function Calling
**Impact**: High  
**Probability**: High  
**Mitigation**:
- Primary: Use structured prompting (implemented in Phase 2)
- Backup: Hybrid approach with OpenAI/Anthropic for tool decisions
- Fallback: Manual tool triggering via slash commands

### Risk 2: Tool Execution Performance
**Impact**: Medium  
**Probability**: Medium  
**Mitigation**:
- Implement aggressive caching
- Use async execution
- Show progressive UI updates
- Set reasonable timeouts (5-30s)

### Risk 3: Security Vulnerabilities
**Impact**: Critical  
**Probability**: Low  
**Mitigation**:
- Mandatory approval for dangerous operations
- Input validation and sanitization
- Sandboxing via OS-level restrictions
- Comprehensive audit logging
- Regular security reviews

### Risk 4: User Experience Complexity
**Impact**: Medium  
**Probability**: Medium  
**Mitigation**:
- Clear visual indicators for tool usage
- Inline help and tooltips
- Sensible defaults
- Progressive disclosure (hide complexity)

---

## Success Criteria

### Technical
- ✅ Successfully connect to 3+ MCP servers
- ✅ Tool discovery < 100ms
- ✅ Tool execution overhead < 500ms
- ✅ Zero security incidents
- ✅ 95%+ test coverage

### User Experience
- ✅ Tool calls feel natural and fast
- ✅ Approval workflow < 3 clicks
- ✅ Clear visual feedback
- ✅ Error messages are helpful
- ✅ Settings are discoverable

### Business
- ✅ Users can accomplish real tasks
- ✅ Feature is used regularly
- ✅ No support burden from complexity
- ✅ Enables new use cases

---

## Timeline Summary

| Phase | Duration | Key Deliverable |
|-------|----------|-----------------|
| Phase 1: Foundation | Week 1 | MCP client infrastructure |
| Phase 2: Integration | Week 2 | Tool calling pipeline |
| Phase 3: UI/UX | Week 3 | Approval workflow & indicators |
| Phase 4: Testing | Week 4 | Comprehensive test suite |
| Phase 5: Documentation | Week 5 | Complete documentation |

**Total**: 5 weeks for full implementation

---

## Next Steps

1. ✅ Review and approve this plan
2. 📋 Set up development environment with MCP test servers
3. 📋 Begin Phase 1 implementation
4. 📋 Schedule weekly progress reviews
5. 📋 Create GitHub project board for task tracking

---

## References

- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [ex_mcp Documentation](https://github.com/azmaveth/ex_mcp)
- [MCP Servers Repository](https://github.com/modelcontextprotocol/servers)
- [Ollama Chat REQUIREMENTS.md](../REQUIREMENTS.md)
- [MCP Libraries Research](./MCP_LIBRARIES_RESEARCH.md)
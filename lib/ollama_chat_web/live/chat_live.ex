defmodule OllamaChatWeb.ChatLive do
  @moduledoc """
  Main LiveView for the chat interface.

  ## Function Organization

  This module uses feature-based organization rather than grouping all clauses
  of the same function together. This means `handle_event/3` and `handle_info/2`
  clauses are grouped by feature (streaming, tools, recovery, etc.) rather than
  by function name.

  This produces compiler warnings about ungrouped clauses, which are accepted
  as a trade-off for better maintainability in this large module (1900+ lines).

  See KNOWN_ISSUES.md for detailed discussion of this design decision.
  """

  use OllamaChatWeb, :live_view

  alias OllamaChat.{Markdown, MCPClient, MCPPromptBuilder, MCPResponseParser, OllamaClient}

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Ollama Chat")
      |> assign(:loading, false)
      |> assign(:error, nil)
      |> assign(:status_message, nil)
      |> assign(:ollama_status, :unknown)
      |> assign(:available_models, [])
      |> assign(
        :selected_model,
        Application.get_env(:ollama_chat, :ollama_default_model, "llama3")
      )
      |> assign(:streaming_message, "")
      |> assign(:messages_empty?, true)
      |> assign(:form, to_form(%{"message" => ""}))
      |> assign(:message_history, [])
      |> assign(:conversations, [])
      |> assign(:current_conversation_id, nil)
      |> assign(:storage_warning, false)
      |> assign(:system_prompt, "")
      |> assign(:system_prompt_open, false)
      |> assign(:generation_params, default_generation_params())
      |> assign(:generation_params_open, false)
      |> assign(:stream_timeout_ref, nil)
      |> assign(:start_command_configured, OllamaClient.start_command_configured?())
      |> assign(:recovering, false)
      |> assign(:recovery_step, nil)
      |> assign(:mcp_enabled?, MCPClient.enabled?())
      |> assign(:mcp_tools, %{})
      |> assign(:pending_approval, nil)
      |> assign(:show_mcp_settings, false)
      |> assign(:streaming_pid, nil)
      |> stream(:messages, [])

    socket =
      if connected?(socket) and socket.assigns.mcp_enabled? do
        case MCPClient.list_tools() do
          {:ok, tools} ->
            Logger.info("Loaded #{map_size(tools)} MCP tools")
            assign(socket, :mcp_tools, tools)

          {:error, reason} ->
            Logger.warning("Failed to load MCP tools: #{inspect(reason)}")
            socket
        end
      else
        socket
      end

    if connected?(socket) do
      send(self(), :check_ollama_status)
      send(self(), :load_models)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"message" => message}, socket) when is_binary(message) do
    {:noreply, assign(socket, :form, to_form(%{"message" => message}))}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["message"]} = params, socket) do
    message = params["value"] || ""
    {:noreply, assign(socket, :form, to_form(%{"message" => message}))}
  end

  @impl true
  def handle_event("cancel_stream", _params, socket) do
    # Kill the streaming process if it exists
    _exit_result =
      case socket.assigns.streaming_pid do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end

    # Cancel any pending timeout
    _cancel_result =
      case socket.assigns.stream_timeout_ref do
        nil -> :ok
        ref -> Process.cancel_timer(ref)
      end

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:streaming_pid, nil)
      |> assign(:stream_timeout_ref, nil)
      |> assign(:streaming_message, "")

    {:noreply, socket}
  end

  @impl true
  def handle_event("send", %{"message" => message_text}, socket) do
    message = String.trim(message_text)

    if message == "" do
      {:noreply, socket}
    else
      Logger.info(
        "User sent message (#{String.length(message)} chars) to model=#{socket.assigns.selected_model}"
      )

      # Add user message
      user_message = %{
        id: generate_id(),
        role: "user",
        content: message,
        html_content: nil,
        timestamp: DateTime.utc_now()
      }

      # Create assistant message placeholder
      assistant_message_id = generate_id()

      assistant_message = %{
        id: assistant_message_id,
        role: "assistant",
        content: "",
        html_content: nil,
        timestamp: DateTime.utc_now(),
        streaming: true
      }

      # Build conversation history
      messages_for_api =
        [user_message | socket.assigns.message_history]
        |> Enum.reverse()
        |> Enum.map(fn msg ->
          %{role: msg.role, content: msg.content}
        end)

      # Build system prompt (MCP-aware if tools available)
      system_prompt =
        if socket.assigns.mcp_enabled? and map_size(socket.assigns.mcp_tools) > 0 do
          MCPPromptBuilder.build_tool_aware_system_prompt(
            socket.assigns.mcp_tools,
            socket.assigns.system_prompt
          )
        else
          if socket.assigns.system_prompt != "" do
            socket.assigns.system_prompt
          else
            nil
          end
        end

      messages_for_api =
        if system_prompt do
          [%{role: "system", content: system_prompt} | messages_for_api]
        else
          messages_for_api
        end

      socket =
        socket
        |> stream_insert(:messages, user_message)
        |> stream_insert(:messages, assistant_message)
        |> assign(:form, to_form(%{"message" => ""}))
        |> assign(:loading, true)
        |> assign(:error, nil)
        |> assign(:status_message, nil)
        |> assign(:streaming_message, "")
        |> assign(:messages_empty?, false)
        |> assign(:message_history, [user_message | socket.assigns.message_history])

      # Start streaming in a separate process
      parent = self()
      model = socket.assigns.selected_model
      ollama_options = build_ollama_options(socket.assigns.generation_params)

      pid =
        spawn(fn ->
          stream_callback = build_stream_callback(parent, assistant_message_id)

          result =
            OllamaClient.chat_stream(
              messages_for_api,
              stream_callback,
              model: model,
              options: ollama_options
            )

          handle_stream_result(result, parent, assistant_message_id)
        end)

      # Schedule initial stream timeout
      timeout_ref =
        Process.send_after(self(), {:stream_timeout, assistant_message_id}, stream_timeout_ms())

      socket =
        socket
        |> assign(:stream_timeout_ref, timeout_ref)
        |> assign(:streaming_pid, pid)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :selected_model, model)}
  end

  @impl true
  def handle_event("clear_chat", _params, socket) do
    {:noreply, start_new_conversation(socket)}
  end

  @impl true
  def handle_event("load_conversation", %{"conversation_id" => conversation_id}, socket) do
    socket = push_event(socket, "load_conversation", %{conversation_id: conversation_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("conversation_loaded", %{"conversation" => conversation}, socket) do
    messages = conversation["messages"] || []
    Logger.info("Loading conversation id=#{conversation["id"]} with #{length(messages)} messages")

    # Clear existing messages and load conversation
    socket =
      socket
      |> stream(:messages, [], reset: true)
      |> assign(:current_conversation_id, conversation["id"])
      |> assign(:selected_model, conversation["model"])
      |> assign(:message_history, messages)
      |> assign(:messages_empty?, messages == [])
      |> assign(:system_prompt, conversation["system_prompt"] || "")
      |> assign(
        :generation_params,
        restore_generation_params(conversation["generation_params"])
      )

    # Stream all messages, rendering markdown for assistant messages
    socket =
      Enum.reduce(messages, socket, fn msg, acc ->
        html_content =
          if msg["role"] == "assistant",
            do: Markdown.render_to_string(msg["content"]),
            else: nil

        message = %{
          id: "msg-#{msg["timestamp"]}-#{:rand.uniform(10000)}",
          role: msg["role"],
          content: msg["content"],
          html_content: html_content,
          timestamp: msg["timestamp"],
          streaming: false
        }

        stream_insert(acc, :messages, message)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("conversations_loaded", %{"conversations" => conversations}, socket) do
    {:noreply, assign(socket, :conversations, conversations)}
  end

  @impl true
  def handle_event("storage_warning", %{"at_limit" => at_limit}, socket) do
    {:noreply, assign(socket, :storage_warning, at_limit)}
  end

  @impl true
  def handle_event("conversation_saved", %{"conversation_id" => conversation_id}, socket) do
    {:noreply, assign(socket, :current_conversation_id, conversation_id)}
  end

  @impl true
  def handle_event("export_conversation", %{"format" => format}, socket) do
    socket =
      push_event(socket, "export_conversation", %{
        format: format,
        conversation_id: socket.assigns.current_conversation_id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_system_prompt", _params, socket) do
    {:noreply, assign(socket, :system_prompt_open, !socket.assigns.system_prompt_open)}
  end

  @impl true
  def handle_event("update_system_prompt", %{"system_prompt" => prompt}, socket) do
    {:noreply, assign(socket, :system_prompt, prompt)}
  end

  @impl true
  def handle_event("toggle_generation_params", _params, socket) do
    {:noreply, assign(socket, :generation_params_open, !socket.assigns.generation_params_open)}
  end

  @impl true
  def handle_event("update_generation_params", params, socket) do
    current = socket.assigns.generation_params

    updated =
      Enum.reduce(params, current, fn {key, value}, acc ->
        if Map.has_key?(acc, key) do
          Map.put(acc, key, parse_number(value))
        else
          acc
        end
      end)

    {:noreply, assign(socket, :generation_params, updated)}
  end

  @impl true
  def handle_event("reset_generation_params", _params, socket) do
    {:noreply, assign(socket, :generation_params, default_generation_params())}
  end

  @impl true
  def handle_event("start_ollama", _params, socket) do
    if socket.assigns.recovering do
      {:noreply, socket}
    else
      send(self(), {:attempt_recovery, nil})
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:check_ollama_status, socket) do
    status = if OllamaClient.ollama_running?(), do: :running, else: :stopped

    {:noreply, assign(socket, :ollama_status, status)}
  end

  @impl true
  def handle_info(:load_models, socket) do
    case OllamaClient.list_models() do
      {:ok, models} when models != [] ->
        {:noreply,
         socket
         |> assign(:available_models, models)
         |> assign(:selected_model, List.first(models))
         |> assign(:ollama_status, :running)}

      {:ok, []} ->
        Logger.warning("Ollama returned empty model list")
        {:noreply, assign(socket, :available_models, [])}

      {:error, reason} ->
        Logger.error("Failed to load models: #{inspect(reason)}")
        {:noreply, assign(socket, :available_models, [])}
    end
  end

  @impl true
  def handle_info({:stream_chunk, message_id, content}, socket) do
    current = socket.assigns.streaming_message
    new_content = current <> content

    # Check for tool calls if MCP is enabled
    if socket.assigns.mcp_enabled? and MCPResponseParser.contains_tool_call?(new_content) do
      case MCPResponseParser.parse_response(new_content) do
        {:tool_call, tool_name, args} ->
          # Tool call detected - stop streaming and handle it
          cancel_stream_timeout(socket.assigns.stream_timeout_ref)
          Logger.info("Tool call detected: #{tool_name} with args: #{inspect(args)}")

          socket = handle_tool_call(socket, message_id, tool_name, args)
          {:noreply, socket}

        :no_tool_call ->
          # Contains "tool_call" text but not a valid tool call yet, continue streaming
          stream_normal_chunk(socket, message_id, new_content)
      end
    else
      # Normal streaming without tool calls
      stream_normal_chunk(socket, message_id, new_content)
    end
  end

  defp stream_normal_chunk(socket, message_id, new_content) do
    # Update the streaming message
    updated_message = %{
      id: message_id,
      role: "assistant",
      content: new_content,
      html_content: nil,
      timestamp: DateTime.utc_now(),
      streaming: true
    }

    # Reset stream timeout on each chunk
    cancel_stream_timeout(socket.assigns.stream_timeout_ref)

    timeout_ref =
      Process.send_after(self(), {:stream_timeout, message_id}, stream_timeout_ms())

    socket =
      socket
      |> stream_insert(:messages, updated_message)
      |> assign(:streaming_message, new_content)
      |> assign(:stream_timeout_ref, timeout_ref)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_done, message_id}, socket) do
    # Cancel stream timeout
    cancel_stream_timeout(socket.assigns.stream_timeout_ref)

    # Finalize the message with rendered markdown
    raw_content = socket.assigns.streaming_message

    Logger.info(
      "Stream completed for message_id=#{message_id} (#{String.length(raw_content)} chars)"
    )

    final_message = %{
      id: message_id,
      role: "assistant",
      content: raw_content,
      html_content: Markdown.render_to_string(raw_content),
      timestamp: DateTime.utc_now(),
      streaming: false
    }

    updated_history = [final_message | socket.assigns.message_history]

    socket =
      socket
      |> stream_insert(:messages, final_message)
      |> assign(:loading, false)
      |> assign(:streaming_message, "")
      |> assign(:message_history, updated_history)
      |> assign(:ollama_status, :running)
      |> assign(:stream_timeout_ref, nil)
      |> assign(:streaming_pid, nil)

    # Auto-save conversation after each completed exchange
    conversation_data = %{
      messages: Enum.reverse(updated_history),
      model: socket.assigns.selected_model,
      conversation_id: socket.assigns.current_conversation_id,
      system_prompt: socket.assigns.system_prompt,
      generation_params: socket.assigns.generation_params
    }

    socket = push_event(socket, "save_conversation", conversation_data)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_error, message_id, reason}, socket) do
    Logger.error("Stream error for message_id=#{message_id}: #{inspect(reason)}")

    # Cancel stream timeout
    cancel_stream_timeout(socket.assigns.stream_timeout_ref)

    # Remove the failed assistant message
    socket =
      socket
      |> stream_delete(:messages, %{id: message_id})
      |> assign(:loading, false)
      |> assign(:streaming_message, "")
      |> assign(:stream_timeout_ref, nil)
      |> assign(:streaming_pid, nil)

    # Check if it's a connection error and attempt recovery
    if connection_error?(reason) do
      Logger.info("Connection error detected, initiating recovery")
      send(self(), {:attempt_recovery, message_id})

      {:noreply,
       socket
       |> assign(:ollama_status, :stopped)
       |> assign(:error, nil)}
    else
      {:noreply,
       socket
       |> assign(:error, format_error(reason))
       |> assign(:status_message, nil)}
    end
  end

  @impl true
  def handle_info({:attempt_recovery, _message_id}, socket) do
    if socket.assigns.recovering do
      {:noreply, socket}
    else
      parent = self()

      socket =
        socket
        |> assign(:recovering, true)
        |> assign(:recovery_step, :starting)
        |> assign(:status_message, "Starting Ollama...")
        |> assign(:error, nil)

      spawn(fn -> attempt_ollama_recovery(parent) end)

      {:noreply, socket}
    end
  end

  defp attempt_ollama_recovery(parent) do
    case OllamaClient.start_ollama() do
      :ok ->
        handle_successful_ollama_start(parent)

      {:error, reason} ->
        send(parent, {:recovery_failed, reason})
    end
  end

  defp handle_successful_ollama_start(parent) do
    send(parent, {:recovery_progress, :waiting})
    Process.sleep(2000)

    if OllamaClient.ollama_running?() do
      send(parent, {:recovery_progress, :loading_models})
      Process.sleep(500)
      send(parent, :recovery_complete)
    else
      send(parent, {:recovery_failed, "Ollama started but not responding"})
    end
  end

  @impl true
  def handle_info({:recovery_progress, step}, socket) do
    status_message =
      case step do
        :waiting -> "Waiting for Ollama to initialize..."
        :loading_models -> "Loading models..."
        _ -> "Recovering..."
      end

    {:noreply,
     socket
     |> assign(:recovery_step, step)
     |> assign(:status_message, status_message)}
  end

  @impl true
  def handle_info(:recovery_complete, socket) do
    Logger.info("Ollama recovery successful")

    Process.send_after(self(), :clear_recovery_status, 3000)
    send(self(), :load_models)

    {:noreply,
     socket
     |> assign(:ollama_status, :running)
     |> assign(:recovering, false)
     |> assign(:recovery_step, :success)
     |> assign(:status_message, "Ollama is running!")
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info({:recovery_failed, reason}, socket) do
    Logger.error("Ollama recovery failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:recovering, false)
     |> assign(:recovery_step, nil)
     |> assign(:status_message, nil)
     |> assign(:error, "Failed to start Ollama: #{reason}")}
  end

  # MCP Tool Call Handlers

  @impl true
  def handle_info({:tool_result, message_id, tool_name, result}, socket) do
    Logger.info("Tool #{tool_name} completed successfully")

    # Add tool result message
    tool_result_message = %{
      id: "#{message_id}-tool-result",
      role: "tool_result",
      content: format_tool_result(result),
      tool_name: tool_name,
      timestamp: DateTime.utc_now()
    }

    socket = stream_insert(socket, :messages, tool_result_message)

    # Continue LLM conversation with tool result
    socket = continue_with_tool_result(socket, message_id, tool_name, result)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:tool_error, message_id, tool_name, reason}, socket) do
    Logger.error("Tool #{tool_name} execution failed: #{inspect(reason)}")

    error_message = %{
      id: "#{message_id}-tool-error",
      role: "tool_error",
      content: "Tool execution failed: #{format_error(reason)}",
      tool_name: tool_name,
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> stream_insert(:messages, error_message)
      |> assign(:loading, false)
      |> assign(:streaming_pid, nil)
      |> assign(:error, "Tool execution failed: #{tool_name}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("approve_tool", _params, socket) do
    case socket.assigns.pending_approval do
      nil ->
        {:noreply, socket}

      approval ->
        Logger.info("User approved tool: #{approval.tool_name}")

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
  end

  @impl true
  def handle_event("cancel_tool_approval", _params, socket) do
    Logger.info("User cancelled tool execution")

    socket =
      socket
      |> assign(:pending_approval, nil)
      |> assign(:error, "Tool execution cancelled by user")
      |> assign(:loading, false)
      |> assign(:streaming_pid, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_mcp_settings", _params, socket) do
    {:noreply, assign(socket, :show_mcp_settings, !socket.assigns.show_mcp_settings)}
  end

  @impl true
  def handle_info(:clear_recovery_status, socket) do
    {:noreply,
     socket
     |> assign(:recovery_step, nil)
     |> assign(:status_message, nil)}
  end

  @impl true
  def handle_info({:stream_timeout, message_id}, socket) do
    if socket.assigns.loading do
      Logger.warning(
        "Stream timeout for message_id=#{message_id} after #{stream_timeout_ms()}ms of inactivity"
      )

      socket =
        socket
        |> stream_delete(:messages, %{id: message_id})
        |> assign(:loading, false)
        |> assign(:streaming_pid, nil)
        |> assign(:streaming_message, "")
        |> assign(:stream_timeout_ref, nil)
        |> assign(
          :error,
          "Response timed out — the model stopped sending data. Try again or select a different model."
        )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:clear_status, socket) do
    {:noreply, assign(socket, :status_message, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-900 via-blue-900 to-slate-900">
      <div class="mx-auto max-w-5xl px-4 py-8">
        <%!-- Header --%>
        <div class="mb-8">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-4xl font-bold text-white mb-2">Ollama Chat</h1>
              <div class="flex items-center gap-3">
                <div class="flex items-center gap-2">
                  <div class={[
                    "w-3 h-3 rounded-full",
                    @ollama_status == :running && "bg-green-500 animate-pulse",
                    @ollama_status == :stopped && "bg-red-500",
                    @ollama_status == :unknown && "bg-yellow-500"
                  ]}>
                  </div>
                  <span class="text-sm text-gray-300">
                    {if @ollama_status == :running, do: "Connected", else: "Disconnected"}
                  </span>
                  <%= if @ollama_status == :stopped and @start_command_configured and not @recovering do %>
                    <button
                      phx-click="start_ollama"
                      id="start-ollama-btn"
                      class="ml-1 px-2 py-0.5 text-xs font-medium bg-green-600 hover:bg-green-700 text-white rounded-md transition-colors flex items-center gap-1"
                    >
                      <.icon name="hero-play" class="w-3 h-3" /> Start
                    </button>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="flex items-center gap-4">
              <%!-- Model selector --%>
              <%= if @available_models != [] do %>
                <div class="relative">
                  <label class="text-sm text-gray-300 mb-1 block">Model</label>
                  <select
                    class="bg-slate-800 text-white px-4 py-2 rounded-lg border border-slate-700 focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                    phx-change="select_model"
                    name="model"
                  >
                    <option
                      :for={model <- @available_models}
                      value={model}
                      selected={model == @selected_model}
                    >
                      {model}
                    </option>
                  </select>
                </div>
              <% end %>

              <%!-- Conversations selector --%>
              <div class="relative" id="conversations-dropdown" phx-hook=".ConversationManager">
                <label class="text-sm text-gray-300 mb-1 block">Conversations</label>
                <select
                  class="bg-slate-800 text-white px-4 py-2 rounded-lg border border-slate-700 focus:ring-2 focus:ring-blue-500 focus:border-transparent min-w-[200px]"
                  phx-change="load_conversation"
                  name="conversation_id"
                >
                  <option value="" selected={@current_conversation_id == nil}>
                    <%= if @current_conversation_id == nil do %>
                      ✓
                    <% end %>
                    New Chat
                  </option>
                  <option
                    :for={conv <- @conversations}
                    value={conv["id"]}
                    selected={conv["id"] == @current_conversation_id}
                  >
                    <%= if conv["id"] == @current_conversation_id do %>
                      ✓
                    <% end %>
                    {conv["title"]}
                  </option>
                </select>
              </div>

              <button
                type="button"
                phx-click="clear_chat"
                class="px-4 py-2 bg-slate-800 hover:bg-slate-700 text-white rounded-lg transition-colors border border-slate-700 mt-6"
                title="New Chat"
              >
                <.icon name="hero-plus-circle" class="w-5 h-5" />
              </button>

              <%!-- Export dropdown --%>
              <div class="relative mt-6" id="export-menu">
                <button
                  type="button"
                  phx-click={JS.toggle(to: "#export-options")}
                  disabled={@current_conversation_id == nil}
                  class={[
                    "px-4 py-2 bg-slate-800 text-white rounded-lg transition-colors border border-slate-700",
                    if(@current_conversation_id != nil,
                      do: "hover:bg-slate-700",
                      else: "opacity-50 cursor-not-allowed"
                    )
                  ]}
                  title="Export conversation"
                  id="export-button"
                >
                  <.icon name="hero-arrow-down-tray" class="w-5 h-5" />
                </button>
                <div
                  id="export-options"
                  class="hidden absolute right-0 mt-1 w-48 bg-slate-800 border border-slate-700 rounded-lg shadow-xl z-50 overflow-hidden"
                >
                  <button
                    type="button"
                    phx-click={
                      JS.push("export_conversation", value: %{format: "markdown"})
                      |> JS.toggle(to: "#export-options")
                    }
                    class="w-full text-left px-4 py-2.5 text-sm text-white hover:bg-slate-700 transition-colors flex items-center gap-2"
                    id="export-markdown-btn"
                  >
                    <.icon name="hero-document-text" class="w-4 h-4" /> Export as Markdown
                  </button>
                  <button
                    type="button"
                    phx-click={
                      JS.push("export_conversation", value: %{format: "json"})
                      |> JS.toggle(to: "#export-options")
                    }
                    class="w-full text-left px-4 py-2.5 text-sm text-white hover:bg-slate-700 transition-colors flex items-center gap-2"
                    id="export-json-btn"
                  >
                    <.icon name="hero-code-bracket" class="w-4 h-4" /> Export as JSON
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- System prompt panel --%>
        <div class="mb-4">
          <button
            type="button"
            phx-click="toggle_system_prompt"
            class="flex items-center gap-2 text-sm text-gray-300 hover:text-white transition-colors"
          >
            <.icon
              name={if @system_prompt_open, do: "hero-chevron-down", else: "hero-chevron-right"}
              class="w-4 h-4"
            />
            <span>System Prompt</span>
            <%= if @system_prompt != "" do %>
              <span class="px-2 py-0.5 text-xs bg-blue-600 text-white rounded-full">Active</span>
            <% end %>
          </button>
          <%= if @system_prompt_open do %>
            <div class="mt-2">
              <.form
                for={to_form(%{"system_prompt" => @system_prompt})}
                id="system-prompt-form"
                phx-change="update_system_prompt"
              >
                <textarea
                  name="system_prompt"
                  placeholder="Enter a system prompt to set the model's behavior (e.g., 'You are a helpful coding assistant')..."
                  rows="3"
                  class="w-full bg-slate-800 text-white border border-slate-700 rounded-lg px-4 py-3 text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-y placeholder-slate-500"
                  phx-debounce="500"
                >{@system_prompt}</textarea>
              </.form>
            </div>
          <% end %>
        </div>

        <%!-- MCP Tools panel --%>
        <%= if @mcp_enabled? do %>
          <div class="mb-4">
            <button
              type="button"
              phx-click="toggle_mcp_settings"
              class="flex items-center gap-2 text-sm text-gray-300 hover:text-white transition-colors"
            >
              <.icon
                name={if @show_mcp_settings, do: "hero-chevron-down", else: "hero-chevron-right"}
                class="w-4 h-4"
              />
              <.icon name="hero-wrench-screwdriver" class="w-4 h-4" />
              <span>MCP Tools</span>
              <span class="px-2 py-0.5 text-xs bg-blue-600 text-white rounded-full">
                {map_size(@mcp_tools)}
              </span>
            </button>
            <%= if @show_mcp_settings do %>
              <div class="mt-2 space-y-2 max-h-96 overflow-y-auto">
                <%= if map_size(@mcp_tools) == 0 do %>
                  <p class="text-sm text-gray-400 px-3 py-2">No MCP tools available</p>
                <% else %>
                  <div
                    :for={{name, info} <- @mcp_tools}
                    class="text-xs p-3 bg-slate-800 rounded-lg border border-slate-700"
                  >
                    <div class="flex items-start justify-between gap-2">
                      <div class="flex-1">
                        <div class="font-medium text-blue-300 mb-1">{name}</div>
                        <div class="text-gray-400 text-xs leading-relaxed">{info.description}</div>
                      </div>
                      <%= if info.requires_approval do %>
                        <span class="px-1.5 py-0.5 text-xs bg-yellow-900/50 text-yellow-300 rounded whitespace-nowrap">
                          Requires approval
                        </span>
                      <% end %>
                    </div>
                    <div class="mt-2 text-gray-500 text-xs">
                      Server: <span class="text-gray-400">{info.server}</span>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Generation parameters panel --%>
        <div class="mb-4">
          <button
            type="button"
            phx-click="toggle_generation_params"
            class="flex items-center gap-2 text-sm text-gray-300 hover:text-white transition-colors"
            id="toggle-generation-params"
          >
            <.icon
              name={if @generation_params_open, do: "hero-chevron-down", else: "hero-chevron-right"}
              class="w-4 h-4"
            />
            <span>Generation Parameters</span>
            <%= if generation_params_customized?(@generation_params) do %>
              <span class="px-2 py-0.5 text-xs bg-amber-600 text-white rounded-full">Custom</span>
            <% end %>
          </button>
          <%= if @generation_params_open do %>
            <div
              class="mt-2 bg-slate-800/50 border border-slate-700 rounded-lg p-4"
              id="generation-params-panel"
            >
              <.form
                for={to_form(@generation_params)}
                id="generation-params-form"
                phx-change="update_generation_params"
              >
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <%!-- Temperature --%>
                  <div>
                    <label class="text-sm text-gray-300 flex justify-between mb-1">
                      <span>Temperature</span>
                      <span class="text-blue-400 font-mono">{@generation_params["temperature"]}</span>
                    </label>
                    <input
                      type="range"
                      name="temperature"
                      min="0"
                      max="2"
                      step="0.1"
                      value={@generation_params["temperature"]}
                      class="w-full accent-blue-500"
                    />
                    <div class="flex justify-between text-xs text-slate-500 mt-0.5">
                      <span>Precise</span>
                      <span>Creative</span>
                    </div>
                  </div>
                  <%!-- Max Tokens (num_predict) --%>
                  <div>
                    <label class="text-sm text-gray-300 flex justify-between mb-1">
                      <span>Max Tokens</span>
                      <span class="text-blue-400 font-mono">{@generation_params["num_predict"]}</span>
                    </label>
                    <input
                      type="range"
                      name="num_predict"
                      min="64"
                      max="8192"
                      step="64"
                      value={@generation_params["num_predict"]}
                      class="w-full accent-blue-500"
                    />
                    <div class="flex justify-between text-xs text-slate-500 mt-0.5">
                      <span>64</span>
                      <span>8192</span>
                    </div>
                  </div>
                  <%!-- Top P --%>
                  <div>
                    <label class="text-sm text-gray-300 flex justify-between mb-1">
                      <span>Top P</span>
                      <span class="text-blue-400 font-mono">{@generation_params["top_p"]}</span>
                    </label>
                    <input
                      type="range"
                      name="top_p"
                      min="0"
                      max="1"
                      step="0.05"
                      value={@generation_params["top_p"]}
                      class="w-full accent-blue-500"
                    />
                    <div class="flex justify-between text-xs text-slate-500 mt-0.5">
                      <span>Focused</span>
                      <span>Diverse</span>
                    </div>
                  </div>
                  <%!-- Top K --%>
                  <div>
                    <label class="text-sm text-gray-300 flex justify-between mb-1">
                      <span>Top K</span>
                      <span class="text-blue-400 font-mono">{@generation_params["top_k"]}</span>
                    </label>
                    <input
                      type="range"
                      name="top_k"
                      min="1"
                      max="100"
                      step="1"
                      value={@generation_params["top_k"]}
                      class="w-full accent-blue-500"
                    />
                    <div class="flex justify-between text-xs text-slate-500 mt-0.5">
                      <span>1</span>
                      <span>100</span>
                    </div>
                  </div>
                  <%!-- Context Window (num_ctx) --%>
                  <div class="md:col-span-2">
                    <label class="text-sm text-gray-300 flex justify-between mb-1">
                      <span>Context Window</span>
                      <span class="text-blue-400 font-mono">{@generation_params["num_ctx"]}</span>
                    </label>
                    <input
                      type="range"
                      name="num_ctx"
                      min="512"
                      max="131072"
                      step="512"
                      value={@generation_params["num_ctx"]}
                      class="w-full accent-blue-500"
                    />
                    <div class="flex justify-between text-xs text-slate-500 mt-0.5">
                      <span>512</span>
                      <span>131072</span>
                    </div>
                  </div>
                </div>
                <div class="mt-3 flex justify-end">
                  <button
                    type="button"
                    phx-click="reset_generation_params"
                    class="text-sm text-gray-400 hover:text-white transition-colors px-3 py-1 rounded border border-slate-600 hover:border-slate-500"
                    id="reset-generation-params"
                  >
                    Reset to Defaults
                  </button>
                </div>
              </.form>
            </div>
          <% end %>
        </div>

        <%!-- Status message display --%>
        <%= if @status_message do %>
          <div class={[
            "mb-4 p-4 rounded-lg",
            if(@recovering,
              do: "bg-amber-900/50 border border-amber-500 text-amber-200",
              else: "bg-blue-900/50 border border-blue-500 text-blue-200"
            )
          ]}>
            <div class="flex items-start gap-2">
              <%= if @recovering do %>
                <.icon name="hero-arrow-path" class="w-5 h-5 mt-0.5 flex-shrink-0 animate-spin" />
              <% else %>
                <.icon name="hero-information-circle" class="w-5 h-5 mt-0.5 flex-shrink-0" />
              <% end %>
              <div class="flex-1">
                <p class="text-sm">{@status_message}</p>
                <%= if @recovering do %>
                  <div class="mt-2 flex gap-1" id="recovery-progress">
                    <div class={[
                      "h-1.5 flex-1 rounded-full transition-all duration-300",
                      if(@recovery_step in [:starting, :waiting, :loading_models, :success],
                        do: "bg-amber-400",
                        else: "bg-amber-900"
                      )
                    ]}>
                    </div>
                    <div class={[
                      "h-1.5 flex-1 rounded-full transition-all duration-300",
                      if(@recovery_step in [:waiting, :loading_models, :success],
                        do: "bg-amber-400",
                        else: "bg-amber-900"
                      )
                    ]}>
                    </div>
                    <div class={[
                      "h-1.5 flex-1 rounded-full transition-all duration-300",
                      if(@recovery_step in [:loading_models, :success],
                        do: "bg-amber-400",
                        else: "bg-amber-900"
                      )
                    ]}>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Error display --%>
        <%= if @error do %>
          <div class="mb-4 p-4 bg-red-900/50 border border-red-500 rounded-lg text-red-200">
            <div class="flex items-start gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 mt-0.5 flex-shrink-0" />
              <div>
                <p class="font-semibold">Error</p>
                <p class="text-sm">{@error}</p>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Chat messages --%>
        <div class="bg-slate-800/50 rounded-xl shadow-2xl backdrop-blur-sm border border-slate-700 mb-6 overflow-hidden">
          <div
            id="messages-container"
            phx-hook=".CopyMessage"
            class="h-[600px] overflow-y-auto p-6 space-y-4 relative"
          >
            <%= if @messages_empty? do %>
              <div class="text-center py-20 absolute inset-0 flex flex-col items-center justify-center">
                <.icon
                  name="hero-chat-bubble-left-right"
                  class="w-16 h-16 text-slate-600 mx-auto mb-4"
                />
                <p class="text-slate-400 text-lg">Start a conversation with your local LLM</p>
              </div>
            <% end %>

            <div
              id="messages"
              phx-update="stream"
              phx-hook=".ScrollToBottom"
            >
              <div
                :for={{id, message} <- @streams.messages}
                id={id}
                class="animate-fade-in group"
                data-content={message.content}
              >
                <%= cond do %>
                  <% message.role == "user" -> %>
                    <div class="flex justify-end">
                      <div class="relative">
                        <button
                          type="button"
                          class="copy-btn absolute -left-9 top-2 p-1 rounded text-slate-400 hover:text-white opacity-0 group-hover:opacity-100 transition-opacity"
                          title="Copy message"
                        >
                          <.icon name="hero-clipboard-document" class="w-4 h-4 copy-icon" />
                          <.icon name="hero-check" class="w-4 h-4 check-icon hidden" />
                        </button>
                        <div class="bg-blue-600 text-white rounded-2xl rounded-tr-sm px-6 py-3 max-w-[80%] shadow-lg">
                          <p class="whitespace-pre-wrap break-words">{message.content}</p>
                        </div>
                      </div>
                    </div>
                  <% message.role == "tool_call" or message.role == "tool_result" -> %>
                    <div class="flex justify-center my-2">
                      <details class="bg-slate-800/50 border border-slate-600 rounded-lg max-w-2xl w-full">
                        <summary class="px-4 py-2 cursor-pointer hover:bg-slate-700/50 rounded-lg transition-colors flex items-center gap-2 text-sm text-slate-400">
                          <.icon name="hero-chevron-right" class="w-4 h-4 details-chevron" />
                          <%= if message.role == "tool_call" do %>
                            <.icon name="hero-wrench-screwdriver" class="w-4 h-4 text-blue-400" />
                            <span>
                              Calling tool:
                              <span class="font-mono text-blue-300">{message.tool_name}</span>
                            </span>
                          <% else %>
                            <.icon name="hero-check-circle" class="w-4 h-4 text-green-400" />
                            <span>
                              Tool completed:
                              <span class="font-mono text-green-300">{message.tool_name}</span>
                            </span>
                          <% end %>
                        </summary>
                        <div class="px-4 py-3 border-t border-slate-600">
                          <%= if message.role == "tool_call" do %>
                            <div class="text-sm text-blue-300 mb-2 font-medium">Tool Arguments:</div>
                            <%= if Map.get(message, :args) && map_size(message.args) > 0 do %>
                              <pre class="text-xs text-blue-400 font-mono bg-slate-900/50 rounded p-2 overflow-x-auto">{inspect(message.args, pretty: true)}</pre>
                            <% else %>
                              <div class="text-xs text-slate-400 italic">No arguments</div>
                            <% end %>
                          <% else %>
                            <div class="text-sm text-green-300 mb-2 font-medium">Tool Result:</div>
                            <pre class="text-xs text-green-400 font-mono bg-slate-900/50 rounded p-2 overflow-x-auto whitespace-pre-wrap">{message.content}</pre>
                          <% end %>
                        </div>
                      </details>
                    </div>
                  <% message.role == "tool_error" -> %>
                    <div class="flex justify-center my-4">
                      <div class="bg-red-900/50 border border-red-700 rounded-lg px-4 py-3 max-w-md">
                        <div class="flex items-center gap-3">
                          <.icon name="hero-x-circle" class="w-5 h-5 text-red-400" />
                          <div class="flex-1">
                            <div class="text-sm font-medium text-red-300">
                              Tool failed: {message.tool_name}
                            </div>
                            <div class="text-xs text-red-400 mt-1">
                              {message.content}
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  <% true -> %>
                    <%= if empty_response?(message.content) and not message.streaming do %>
                      <div class="flex justify-center my-2">
                        <details class="bg-slate-800/50 border border-slate-600 rounded-lg max-w-2xl w-full">
                          <summary class="px-4 py-2 cursor-pointer hover:bg-slate-700/50 rounded-lg transition-colors flex items-center gap-2 text-sm text-slate-400">
                            <.icon name="hero-chevron-right" class="w-4 h-4 details-chevron" />
                            <.icon
                              name="hero-chat-bubble-left-ellipsis"
                              class="w-4 h-4 text-slate-400"
                            />
                            <span>Intermediate response (empty)</span>
                          </summary>
                          <div class="px-4 py-3 border-t border-slate-600">
                            <div class="text-xs text-slate-400 italic">
                              This response contained only whitespace.
                            </div>
                          </div>
                        </details>
                      </div>
                    <% else %>
                      <div class="flex justify-start">
                        <div class="relative">
                          <%= if not message.streaming do %>
                            <button
                              type="button"
                              class="copy-btn absolute -right-9 top-2 p-1 rounded text-slate-400 hover:text-white opacity-0 group-hover:opacity-100 transition-opacity"
                              title="Copy message"
                            >
                              <.icon name="hero-clipboard-document" class="w-4 h-4 copy-icon" />
                              <.icon name="hero-check" class="w-4 h-4 check-icon hidden" />
                            </button>
                          <% end %>
                          <div class="bg-slate-700 text-white rounded-2xl rounded-tl-sm px-6 py-3 max-w-[80%] shadow-lg">
                            <%= if message.streaming do %>
                              <p class="whitespace-pre-wrap break-words">{message.content}</p>
                              <span class="inline-block w-2 h-4 bg-white ml-1 animate-pulse"></span>
                            <% else %>
                              <div class="prose-chat">{raw(message.html_content)}</div>
                            <% end %>
                          </div>
                        </div>
                      </div>
                    <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Tool Approval Modal --%>
          <%= if @pending_approval do %>
            <div
              class="fixed inset-0 bg-black/70 flex items-center justify-center z-50 p-4"
              phx-click="cancel_tool_approval"
            >
              <div
                class="bg-slate-800 border border-slate-700 rounded-lg p-6 max-w-lg w-full mx-4 shadow-2xl"
                phx-click-stop
              >
                <div class="flex items-center gap-3 mb-4">
                  <.icon name="hero-shield-exclamation" class="w-8 h-8 text-yellow-400" />
                  <h3 class="text-xl font-bold text-white">Tool Approval Required</h3>
                </div>

                <div class="space-y-3 mb-6">
                  <div>
                    <div class="text-sm font-medium text-gray-400">Tool</div>
                    <div class="text-lg text-white font-mono">{@pending_approval.tool_name}</div>
                  </div>

                  <div>
                    <div class="text-sm font-medium text-gray-400">Description</div>
                    <div class="text-white">{@pending_approval.tool_info.description}</div>
                  </div>

                  <div>
                    <div class="text-sm font-medium text-gray-400 mb-1">Arguments</div>
                    <pre class="text-sm text-gray-300 bg-slate-900 p-3 rounded overflow-x-auto">{Jason.encode!(@pending_approval.args, pretty: true)}</pre>
                  </div>
                </div>

                <div class="flex gap-3">
                  <button
                    type="button"
                    phx-click="approve_tool"
                    class="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 text-white font-medium rounded-lg transition-colors"
                  >
                    Approve
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_tool_approval"
                    class="flex-1 px-4 py-2 bg-red-600 hover:bg-red-700 text-white font-medium rounded-lg transition-colors"
                  >
                    Deny
                  </button>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Input form --%>
          <div class="border-t border-slate-700 bg-slate-800/80 p-4">
            <.form for={@form} id="chat-form" phx-submit="send" phx-change="validate">
              <div class="flex gap-3 items-end">
                <div class="flex-1 max-w-full overflow-auto max-h-[500px]">
                  <.input
                    field={@form[:message]}
                    type="textarea"
                    placeholder="Type your message... (Click Send to submit)"
                    autocomplete="off"
                    disabled={@loading}
                    rows="4"
                    phx-hook=".PreventEnterSubmit"
                    class="w-full bg-slate-900 text-white border-slate-600 focus:border-blue-500 focus:ring-blue-500 resize-y min-h-[100px] px-4 py-3"
                  />
                </div>
                <%= if @loading do %>
                  <button
                    type="button"
                    phx-click="cancel_stream"
                    class={[
                      "px-6 py-3 rounded-lg font-medium transition-all duration-200",
                      "bg-red-600 hover:bg-red-700 text-white",
                      "flex items-center gap-2 flex-shrink-0"
                    ]}
                  >
                    <.icon name="hero-x-circle" class="w-5 h-5" />
                    <span>Cancel</span>
                  </button>
                <% else %>
                  <button
                    type="submit"
                    class={[
                      "px-6 py-3 rounded-lg font-medium transition-all duration-200",
                      "bg-blue-600 hover:bg-blue-700 text-white",
                      "flex items-center gap-2 flex-shrink-0"
                    ]}
                  >
                    <.icon name="hero-paper-airplane" class="w-5 h-5" />
                    <span>Send</span>
                  </button>
                <% end %>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Footer info --%>
        <div class="text-center text-sm text-slate-400">
          <p>
            Powered by Ollama • Model:
            <span class="text-blue-400 font-medium">{@selected_model}</span>
          </p>
        </div>
      </div>
    </div>

    <%!-- Auto-scroll to bottom hook --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
      export default {
        mounted() {
          this.scrollToBottom();
        },
        updated() {
          this.scrollToBottom();
        },
        scrollToBottom() {
          this.el.scrollTop = this.el.scrollHeight;
        }
      }
    </script>

    <%!-- Copy message to clipboard hook (event delegation) --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyMessage">
      export default {
        mounted() {
          this.el.addEventListener("click", (e) => {
            const btn = e.target.closest(".copy-btn");
            if (!btn) return;

            const messageEl = btn.closest("[data-content]");
            if (!messageEl) return;

            const content = messageEl.getAttribute("data-content");
            navigator.clipboard.writeText(content).then(() => {
              const copyIcon = btn.querySelector(".copy-icon");
              const checkIcon = btn.querySelector(".check-icon");
              if (copyIcon && checkIcon) {
                copyIcon.classList.add("hidden");
                checkIcon.classList.remove("hidden");
                setTimeout(() => {
                  copyIcon.classList.remove("hidden");
                  checkIcon.classList.add("hidden");
                }, 2000);
              }
            });
          });
        }
      }
    </script>

    <%!-- Prevent Enter key from submitting form --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PreventEnterSubmit">
      export default {
        mounted() {
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
              // Allow Enter to insert newline, but prevent form submission
              e.stopPropagation();
            }
          });
        }
      }
    </script>

    <%!-- Conversation Manager hook for localStorage persistence --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ConversationManager">
      export default {
        mounted() {
          this.storageKey = "ollama_chat_conversations";
          this.maxConversations = 100;
          this.warnAtConversations = 90;

          // Load conversations from localStorage
          this.loadConversations();

          // Listen for save events from LiveView
          this.handleEvent("save_conversation", (data) => {
            this.saveConversation(data);
          });

          // Listen for new conversation events
          this.handleEvent("new_conversation", () => {
            this.pushEvent("conversations_loaded", { conversations: this.getConversations() });
          });

          // Listen for export events
          this.handleEvent("export_conversation", ({ format, conversation_id }) => {
            const conversation = this.getConversation(conversation_id);
            if (!conversation) return;

            let content, filename, mimeType;

            if (format === "markdown") {
              content = this.formatAsMarkdown(conversation);
              filename = this.sanitizeFilename(conversation.title) + ".md";
              mimeType = "text/markdown";
            } else {
              content = JSON.stringify(conversation, null, 2);
              filename = this.sanitizeFilename(conversation.title) + ".json";
              mimeType = "application/json";
            }

            this.downloadFile(content, filename, mimeType);
          });

          // Listen for load conversation events
          this.handleEvent("load_conversation", (data) => {
            const conversation = this.getConversation(data.conversation_id);
            if (conversation) {
              this.pushEvent("conversation_loaded", { conversation: conversation });
            }
          });
        },

        loadConversations() {
          const conversations = this.getConversations();
          this.pushEvent("conversations_loaded", { conversations: conversations });

          // Check storage warning
          if (conversations.length >= this.warnAtConversations) {
            this.pushEvent("storage_warning", { at_limit: conversations.length >= this.maxConversations });
          }
        },

        getConversations() {
          try {
            const data = localStorage.getItem(this.storageKey);
            if (!data) return [];

            const parsed = JSON.parse(data);
            // Return sorted by updated_at descending (newest first)
            return parsed.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at));
          } catch (e) {
            console.error("Error loading conversations:", e);
            // Notify user of localStorage corruption
            this.pushEvent("storage_error", {
              message: "Failed to load conversation history. Data may be corrupted."
            });
            return [];
          }
        },

        getConversation(id) {
          const conversations = this.getConversations();
          return conversations.find(c => c.id === id);
        },

        saveConversation(data) {
          const { messages, model, conversation_id, system_prompt, generation_params } = data;

          if (!messages || messages.length === 0) return;

          const conversations = this.getConversations();
          const now = new Date().toISOString();

          // Generate conversation ID if not provided
          const convId = conversation_id || `conv-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

          // Generate title from first user message (first 50 chars)
          const firstUserMessage = messages.find(m => m.role === "user");
          const title = firstUserMessage
            ? firstUserMessage.content.substring(0, 50) + (firstUserMessage.content.length > 50 ? "..." : "")
            : "Untitled Conversation";

          // Find existing conversation or create new
          const existingIndex = conversations.findIndex(c => c.id === convId);

          const conversation = {
            id: convId,
            title: title,
            model: model,
            messages: messages,
            system_prompt: system_prompt || "",
            generation_params: generation_params || null,
            created_at: existingIndex >= 0 ? conversations[existingIndex].created_at : now,
            updated_at: now
          };

          if (existingIndex >= 0) {
            // Update existing
            conversations[existingIndex] = conversation;
          } else {
            // Check if we need to remove old conversations
            if (conversations.length >= this.maxConversations) {
              // Remove oldest conversation (last in sorted array)
              const removed = conversations.pop();
              // TODO: Offer export before deletion
              console.log("Removed oldest conversation:", removed.title);
            }

            // Add new conversation
            conversations.unshift(conversation);
          }

          // Save to localStorage
          try {
            localStorage.setItem(this.storageKey, JSON.stringify(conversations));

            // Update LiveView with current conversation ID
            this.pushEvent("conversation_saved", { conversation_id: convId });

            // Reload conversation list
            this.loadConversations();
          } catch (e) {
            console.error("Error saving conversation:", e);
            // Notify user of storage errors
            const errorMessage = e.name === "QuotaExceededError"
              ? "Storage quota exceeded. Consider exporting and deleting old conversations."
              : `Failed to save conversation: ${e.message || "Unknown error"}`;
            this.pushEvent("storage_error", { message: errorMessage });
          }
        },

        formatAsMarkdown(conversation) {
          let md = `# ${conversation.title}\n\n`;
          md += `**Model:** ${conversation.model}\n`;
          md += `**Date:** ${conversation.created_at}\n`;

          if (conversation.system_prompt) {
            md += `**System Prompt:** ${conversation.system_prompt}\n`;
          }

          md += `\n---\n\n`;

          for (const msg of (conversation.messages || [])) {
            const role = msg.role === "user" ? "User" : "Assistant";
            md += `### ${role}\n\n${msg.content}\n\n`;
          }

          return md.trimEnd() + "\n";
        },

        sanitizeFilename(title) {
          return (title || "conversation")
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, "-")
            .replace(/^-|-$/g, "")
            .substring(0, 50);
        },

        downloadFile(content, filename, mimeType) {
          const blob = new Blob([content], { type: mimeType });
          const url = URL.createObjectURL(blob);
          const a = document.createElement("a");
          a.href = url;
          a.download = filename;
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          URL.revokeObjectURL(url);
        },

        formatTimestamp(timestamp) {
          const date = new Date(timestamp);
          const now = new Date();
          const isToday = date.toDateString() === now.toDateString();

          if (isToday) {
            // Relative time for today
            const diffMs = now - date;
            const diffMins = Math.floor(diffMs / 60000);
            const diffHours = Math.floor(diffMs / 3600000);

            if (diffMins < 1) return "Just now";
            if (diffMins < 60) return `${diffMins} minute${diffMins > 1 ? 's' : ''} ago`;
            if (diffHours < 24) return `${diffHours} hour${diffHours > 1 ? 's' : ''} ago`;
          }

          // Absolute time for older dates
          return date.toLocaleDateString('en-US', {
            month: 'short',
            day: 'numeric',
            year: date.getFullYear() !== now.getFullYear() ? 'numeric' : undefined,
            hour: 'numeric',
            minute: '2-digit'
          });
        }
      }
    </script>
    """
  end

  # Helper functions

  defp generate_id do
    "msg-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp start_new_conversation(socket) do
    socket
    |> stream(:messages, [], reset: true)
    |> assign(:messages_empty?, true)
    |> assign(:streaming_message, "")
    |> assign(:error, nil)
    |> assign(:status_message, nil)
    |> assign(:recovering, false)
    |> assign(:recovery_step, nil)
    |> assign(:message_history, [])
    |> assign(:current_conversation_id, nil)
    |> assign(:system_prompt, "")
    |> assign(:system_prompt_open, false)
    |> assign(:generation_params, default_generation_params())
    |> assign(:generation_params_open, false)
    |> push_event("new_conversation", %{})
  end

  defp connection_error?(reason) do
    cond do
      is_struct(reason, Req.TransportError) ->
        reason.reason == :econnrefused or reason.reason == :timeout

      is_binary(reason) ->
        String.contains?(reason, ["connection refused", "econnrefused", "timeout"])

      is_map(reason) ->
        Map.get(reason, :reason) in [:econnrefused, :timeout]

      true ->
        false
    end
  end

  defp default_generation_params do
    %{
      "temperature" => 0.8,
      "num_predict" => 2048,
      "top_p" => 0.9,
      "top_k" => 40,
      "num_ctx" => 4096
    }
  end

  defp build_ollama_options(params) do
    defaults = default_generation_params()

    # Whitelist of allowed parameter keys that can be converted to atoms
    allowed_keys = ~w(temperature num_predict top_p top_k num_ctx)

    params
    |> Enum.reject(fn {key, value} -> Map.get(defaults, key) == value end)
    |> Enum.filter(fn {key, _value} -> key in allowed_keys end)
    |> Enum.into(%{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp restore_generation_params(nil), do: default_generation_params()

  defp restore_generation_params(params) when is_map(params) do
    defaults = default_generation_params()
    Map.merge(defaults, Map.take(params, Map.keys(defaults)))
  end

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} ->
        if float == trunc(float), do: trunc(float), else: float

      _ ->
        value
    end
  end

  defp parse_number(value), do: value

  defp generation_params_customized?(params) do
    params != default_generation_params()
  end

  # MCP Tool Handling Functions

  defp handle_tool_call(socket, message_id, tool_name, args) do
    tool_info = Map.get(socket.assigns.mcp_tools, tool_name)

    if tool_info do
      # Validate arguments
      case MCPResponseParser.validate_arguments(args, tool_info.schema) do
        :ok ->
          if tool_info.requires_approval do
            # Request user approval
            Logger.info("Tool #{tool_name} requires approval")

            socket
            |> assign(:pending_approval, %{
              message_id: message_id,
              tool_name: tool_name,
              tool_info: tool_info,
              args: args
            })
            |> assign(:loading, false)
            |> assign(:streaming_pid, nil)
          else
            # Execute immediately
            execute_mcp_tool(socket, message_id, tool_name, args)
          end

        {:error, validation_error} ->
          Logger.warning("Tool argument validation failed: #{validation_error}")

          socket
          |> assign(:error, "Invalid tool arguments: #{validation_error}")
          |> assign(:loading, false)
          |> assign(:streaming_pid, nil)
      end
    else
      Logger.warning("Unknown tool requested: #{tool_name}")

      socket
      |> assign(:error, "Unknown tool: #{tool_name}")
      |> assign(:loading, false)
      |> assign(:streaming_pid, nil)
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

    socket = stream_insert(socket, :messages, tool_call_message)

    # Execute tool in background
    parent = self()

    spawn(fn ->
      case MCPClient.call_tool(tool_name, args) do
        {:ok, result} ->
          send(parent, {:tool_result, message_id, tool_name, result})

        {:error, reason} ->
          send(parent, {:tool_error, message_id, tool_name, reason})
      end
    end)

    assign(socket, :loading, true)
  end

  defp continue_with_tool_result(socket, _message_id, tool_name, result) do
    # Build tool result message for LLM context
    tool_result_text = MCPPromptBuilder.build_tool_result_message(tool_name, result)

    # Add tool result to conversation history
    tool_result_msg = %{
      role: "system",
      content: tool_result_text
    }

    # Build messages for API including tool result
    messages_for_api =
      [
        tool_result_msg
        | [%{role: "user", content: "Continue your response."} | socket.assigns.message_history]
      ]
      |> Enum.reverse()
      |> Enum.map(fn msg ->
        %{role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]}
      end)

    # Add system prompt with tools
    system_prompt =
      if socket.assigns.mcp_enabled? and map_size(socket.assigns.mcp_tools) > 0 do
        MCPPromptBuilder.build_tool_aware_system_prompt(
          socket.assigns.mcp_tools,
          socket.assigns.system_prompt
        )
      else
        socket.assigns.system_prompt
      end

    messages_for_api =
      if system_prompt && system_prompt != "" do
        [%{role: "system", content: system_prompt} | messages_for_api]
      else
        messages_for_api
      end

    # Create new assistant message for continuation
    continuation_message_id = generate_id()

    continuation_message = %{
      id: continuation_message_id,
      role: "assistant",
      content: "",
      html_content: nil,
      timestamp: DateTime.utc_now(),
      streaming: true
    }

    socket = stream_insert(socket, :messages, continuation_message)

    # Start streaming continuation
    parent = self()
    model = socket.assigns.selected_model
    ollama_options = build_ollama_options(socket.assigns.generation_params)

    pid =
      spawn(fn ->
        result =
          OllamaClient.chat_stream(
            messages_for_api,
            fn chunk ->
              if chunk["message"] && chunk["message"]["content"] do
                send(
                  parent,
                  {:stream_chunk, continuation_message_id, chunk["message"]["content"]}
                )
              end

              if chunk["done"] do
                send(parent, {:stream_done, continuation_message_id})
              end
            end,
            model: model,
            options: ollama_options
          )

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            send(parent, {:stream_error, continuation_message_id, reason})
        end
      end)

    # Reset streaming state
    socket =
      socket
      |> assign(:streaming_message, "")
      |> assign(:loading, true)
      |> assign(:streaming_pid, pid)

    socket
  end

  defp empty_response?(content) when is_binary(content) do
    String.trim(content) == ""
  end

  defp empty_response?(_), do: false

  defp format_tool_result(result) when is_list(result) do
    Enum.map_join(result, "\n\n", fn
      %{"type" => "text", "text" => text} ->
        text

      %{"type" => "image", "mimeType" => mime_type} ->
        "[Image: #{mime_type}]"

      %{"type" => "resource", "uri" => uri} ->
        "[Resource: #{uri}]"

      other ->
        inspect(other)
    end)
  end

  defp format_tool_result(result), do: inspect(result)

  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) when is_map(reason) do
    case reason do
      %{reason: :econnrefused} -> "Cannot connect to Ollama server"
      %{reason: :timeout} -> "Connection to Ollama timed out"
      _ -> "An error occurred: #{inspect(reason)}"
    end
  end

  defp format_error(reason), do: "An error occurred: #{inspect(reason)}"

  defp build_stream_callback(parent, message_id) do
    fn chunk ->
      if chunk["message"] && chunk["message"]["content"] do
        send(parent, {:stream_chunk, message_id, chunk["message"]["content"]})
      end

      if chunk["done"] do
        send(parent, {:stream_done, message_id})
      end
    end
  end

  defp handle_stream_result(result, parent, message_id) do
    case result do
      :ok ->
        :ok

      {:error, reason} ->
        send(parent, {:stream_error, message_id, reason})
    end
  end

  defp stream_timeout_ms do
    Application.get_env(:ollama_chat, :stream_timeout_ms, 30_000)
  end

  defp cancel_stream_timeout(nil), do: :ok

  defp cancel_stream_timeout(ref) do
    _result = Process.cancel_timer(ref)
    :ok
  end
end

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
      |> assign(:streaming_events, [])
      |> assign(:activity_expanded, false)
      |> assign(:streaming_message_id, nil)
      |> assign(:messages_empty?, true)
      |> assign(:form, to_form(%{"message" => ""}))
      |> assign(:message_history, [])
      |> assign(:conversations, [])
      |> assign(:current_conversation_id, nil)
      |> assign(:storage_warning, false)
      |> assign(:storage_error, nil)
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
      |> assign(:mcp_server_status, %{})
      |> assign(:pending_approval, nil)
      |> assign(:show_mcp_settings, false)
      |> assign(:streaming_pid, nil)
      |> assign(:attachments, [])
      |> assign(:context_attachments, [])
      |> stream(:messages, [])
      |> allow_upload(:files,
        accept: :any,
        max_entries: 5,
        max_file_size: 10_000_000,
        auto_upload: true
      )

    socket =
      if connected?(socket) and socket.assigns.mcp_enabled? do
        # Load tools and server status
        socket =
          case MCPClient.list_tools() do
            {:ok, tools} ->
              Logger.info("Loaded #{map_size(tools)} MCP tools")
              assign(socket, :mcp_tools, tools)

            {:error, reason} ->
              Logger.warning("Failed to load MCP tools: #{inspect(reason)}")
              socket
          end

        # Get initial server status
        server_status = MCPClient.server_info()
        socket = assign(socket, :mcp_server_status, server_status)

        # Schedule periodic MCP status updates
        Process.send_after(self(), :refresh_mcp_status, 10_000)

        socket
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
      |> assign(:streaming_events, [])
      |> assign(:activity_expanded, false)
      |> assign(:streaming_message_id, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_attachment", %{"ref" => ref}, socket) do
    attachments = Enum.reject(socket.assigns.attachments, fn att -> att.ref == ref end)
    {:noreply, assign(socket, :attachments, attachments)}
  end

  @impl true
  def handle_event("remove_context_attachment", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    context_attachments = List.delete_at(socket.assigns.context_attachments, index)
    {:noreply, assign(socket, :context_attachments, context_attachments)}
  end

  @impl true
  def handle_event("clear_all_context", _params, socket) do
    {:noreply, assign(socket, :context_attachments, [])}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("send", %{"message" => message_text}, socket) do
    message = String.trim(message_text)

    # Process any uploaded files
    uploaded_files =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        dest = Path.join([System.tmp_dir(), "ollama_chat_uploads", entry.uuid])
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(path, dest)

        {:ok,
         %{
           name: entry.client_name,
           path: dest,
           content_type: entry.client_type,
           size: entry.client_size
         }}
      end)

    # Combine uploaded files with existing attachments
    new_attachments = socket.assigns.attachments ++ uploaded_files

    # Add new attachments to persistent context
    all_context_attachments = socket.assigns.context_attachments ++ new_attachments

    if message == "" and new_attachments == [] do
      {:noreply, socket}
    else
      # Read all context attachment contents (persistent + new)
      context_contents = read_attachments(all_context_attachments)

      # Combine message with all attachment contents in context
      full_message = build_message_with_attachments(message, context_contents)

      Logger.info(
        "User sent message (#{String.length(message)} chars) to model=#{socket.assigns.selected_model}"
      )

      # Add user message
      user_message = %{
        id: generate_id(),
        role: "user",
        content: full_message,
        html_content: nil,
        timestamp: DateTime.utc_now(),
        attachments: new_attachments
      }

      # Create assistant message placeholder
      assistant_message_id = generate_id()

      assistant_message = %{
        id: assistant_message_id,
        role: "assistant",
        content: "",
        html_content: nil,
        timestamp: DateTime.utc_now(),
        streaming: true,
        intermediate_events: []
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
        |> assign(:streaming_events, [])
        |> assign(:activity_expanded, false)
        |> assign(:streaming_message_id, assistant_message_id)
        |> assign(:messages_empty?, false)
        |> assign(:message_history, [user_message | socket.assigns.message_history])
        |> assign(:attachments, [])
        |> assign(:context_attachments, all_context_attachments)

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
          streaming: false,
          intermediate_events: []
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
  def handle_event("storage_error", %{"message" => message}, socket) do
    Logger.warning("Storage error: #{message}")
    {:noreply, assign(socket, :storage_error, message)}
  end

  @impl true
  def handle_event("dismiss_storage_error", _params, socket) do
    {:noreply, assign(socket, :storage_error, nil)}
  end

  @impl true
  def handle_event("delete_conversation", %{"conversation_id" => conversation_id}, socket) do
    socket = push_event(socket, "delete_conversation", %{conversation_id: conversation_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("conversation_deleted", %{"conversation_id" => conversation_id}, socket) do
    socket =
      if conversation_id == socket.assigns.current_conversation_id do
        start_new_conversation(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_all_conversations", _params, socket) do
    socket = push_event(socket, "clear_all_conversations", %{})
    {:noreply, socket}
  end

  @impl true
  def handle_event("all_conversations_cleared", _params, socket) do
    socket =
      socket
      |> start_new_conversation()
      |> assign(:conversations, [])

    {:noreply, socket}
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
  def handle_event("toggle_activity", _params, socket) do
    {:noreply, assign(socket, :activity_expanded, !socket.assigns.activity_expanded)}
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
    # Capture intermediate events for collapsible container
    current_events = socket.assigns.streaming_events

    # Add current content as a streaming event (only if content changed)
    last_event = List.last(current_events)

    should_add =
      current_events == [] or
        (last_event && last_event.type == :chunk && last_event.content != new_content) or
        (last_event && last_event.type != :chunk)

    updated_events =
      if should_add do
        current_events ++ [%{type: :chunk, content: new_content, timestamp: DateTime.utc_now()}]
      else
        current_events
      end

    Logger.debug(
      "Streaming: message_id=#{message_id}, events=#{length(updated_events)}, content_length=#{String.length(new_content)}"
    )

    # Update the streaming message
    updated_message = %{
      id: message_id,
      role: "assistant",
      content: new_content,
      html_content: nil,
      timestamp: DateTime.utc_now(),
      streaming: true,
      intermediate_events: []
    }

    # Reset stream timeout on each chunk
    cancel_stream_timeout(socket.assigns.stream_timeout_ref)

    timeout_ref =
      Process.send_after(self(), {:stream_timeout, message_id}, stream_timeout_ms())

    socket =
      socket
      |> stream_insert(:messages, updated_message)
      |> assign(:streaming_message, new_content)
      |> assign(:streaming_events, updated_events)
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

    # Capture intermediate events (excluding the final chunk) for the collapsible container
    intermediate =
      Enum.reject(socket.assigns.streaming_events, fn e ->
        e == List.last(socket.assigns.streaming_events) and e.type == :chunk
      end)

    final_message = %{
      id: message_id,
      role: "assistant",
      content: raw_content,
      html_content: Markdown.render_to_string(raw_content),
      timestamp: DateTime.utc_now(),
      streaming: false,
      intermediate_events: intermediate
    }

    updated_history = [final_message | socket.assigns.message_history]

    socket =
      socket
      |> stream_insert(:messages, final_message)
      |> assign(:loading, false)
      |> assign(:streaming_message, "")
      |> assign(:streaming_events, [])
      |> assign(:activity_expanded, false)
      |> assign(:streaming_message_id, nil)
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
      |> assign(:streaming_events, [])
      |> assign(:activity_expanded, false)
      |> assign(:streaming_message_id, nil)
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

    # Add to streaming events instead of separate message
    current_events = socket.assigns.streaming_events

    updated_events =
      current_events ++
        [
          %{
            type: :tool_result,
            tool_name: tool_name,
            content: format_tool_result(result),
            timestamp: DateTime.utc_now()
          }
        ]

    socket = assign(socket, :streaming_events, updated_events)

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
    # Refresh status when opening the panel
    socket =
      if socket.assigns.mcp_enabled? and not socket.assigns.show_mcp_settings do
        server_status = MCPClient.server_info()
        assign(socket, :mcp_server_status, server_status)
      else
        socket
      end

    {:noreply, assign(socket, :show_mcp_settings, !socket.assigns.show_mcp_settings)}
  end

  @impl true
  def handle_info(:refresh_mcp_status, socket) do
    if socket.assigns.mcp_enabled? do
      server_status = MCPClient.server_info()

      # Schedule next update
      Process.send_after(self(), :refresh_mcp_status, 10_000)

      {:noreply, assign(socket, :mcp_server_status, server_status)}
    else
      {:noreply, socket}
    end
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
        |> assign(:streaming_events, [])
        |> assign(:activity_expanded, false)
        |> assign(:streaming_message_id, nil)
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
      <div class="mx-auto max-w-7xl px-4 py-8 xl:flex xl:gap-6">
        <%!-- Sidebar (left column on wide screens) --%>
        <div class="xl:w-80 xl:flex-shrink-0 xl:sticky xl:top-8 xl:self-start xl:max-h-[calc(100vh-4rem)] xl:overflow-y-auto mb-6 xl:mb-0">
          <%!-- Header --%>
          <div class="mb-6">
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

          <%!-- Model selector --%>
          <%= if @available_models != [] do %>
            <div class="mb-4">
              <label class="text-sm text-gray-300 mb-1 block">Model</label>
              <select
                class="w-full bg-slate-800 text-white px-4 py-2 rounded-lg border border-slate-700 focus:ring-2 focus:ring-blue-500 focus:border-transparent"
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

          <%!-- Conversations list --%>
          <div class="mb-4" id="conversations-dropdown" phx-hook=".ConversationManager">
            <label class="text-sm text-gray-300 mb-1 block">Conversations</label>
            <div class="bg-slate-800 rounded-lg border border-slate-700 overflow-hidden">
              <%!-- New Chat row --%>
              <button
                type="button"
                phx-click="clear_chat"
                id="new-chat-btn"
                class={[
                  "w-full text-left px-3 py-2.5 flex items-center gap-2 transition-colors text-sm",
                  if(@current_conversation_id == nil,
                    do: "bg-blue-900/30 border-l-2 border-blue-500 text-blue-200",
                    else: "text-gray-300 hover:bg-slate-700 border-l-2 border-transparent"
                  )
                ]}
              >
                <.icon name="hero-plus-circle" class="w-4 h-4 flex-shrink-0" />
                <span class="truncate">New Chat</span>
              </button>
              <%!-- Scrollable conversation list --%>
              <div class="max-h-64 overflow-y-auto">
                <div
                  :for={conv <- @conversations}
                  class={[
                    "group flex items-center gap-2 px-3 py-2 transition-colors text-sm border-l-2 cursor-pointer",
                    if(conv["id"] == @current_conversation_id,
                      do: "bg-blue-900/30 border-blue-500 text-blue-200",
                      else: "border-transparent text-gray-300 hover:bg-slate-700"
                    )
                  ]}
                >
                  <button
                    type="button"
                    phx-click="load_conversation"
                    phx-value-conversation_id={conv["id"]}
                    class="flex items-center gap-2 flex-1 min-w-0 text-left"
                    id={"conv-#{conv["id"]}"}
                  >
                    <.icon name="hero-chat-bubble-left" class="w-4 h-4 flex-shrink-0" />
                    <span class="truncate">{conv["title"]}</span>
                  </button>
                  <button
                    type="button"
                    phx-click="delete_conversation"
                    phx-value-conversation_id={conv["id"]}
                    data-confirm="Delete this conversation? This cannot be undone."
                    class="p-1 text-slate-500 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-all flex-shrink-0"
                    title="Delete conversation"
                    id={"delete-conv-#{conv["id"]}"}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Action buttons --%>
          <div class="flex items-center gap-2 mb-4">
            <%!-- Export dropdown --%>
            <div class="relative" id="export-menu">
              <button
                type="button"
                phx-click={JS.toggle(to: "#export-options")}
                disabled={@current_conversation_id == nil}
                class={[
                  "px-4 py-2 bg-slate-800 text-white rounded-lg transition-colors border border-slate-700 flex items-center gap-2",
                  if(@current_conversation_id != nil,
                    do: "hover:bg-slate-700",
                    else: "opacity-50 cursor-not-allowed"
                  )
                ]}
                title="Export conversation"
                id="export-button"
              >
                <.icon name="hero-arrow-down-tray" class="w-5 h-5" />
                <span class="text-sm">Export</span>
              </button>
              <div
                id="export-options"
                class="hidden absolute left-0 mt-1 w-48 bg-slate-800 border border-slate-700 rounded-lg shadow-xl z-50 overflow-hidden"
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
                  <.icon name="hero-document-text" class="w-4 h-4" /> Markdown
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
                  <.icon name="hero-code-bracket" class="w-4 h-4" /> JSON
                </button>
              </div>
            </div>

            <%!-- Clear All button --%>
            <button
              type="button"
              phx-click="clear_all_conversations"
              data-confirm="Delete ALL conversations? This cannot be undone."
              disabled={@conversations == []}
              class={[
                "px-4 py-2 bg-slate-800 text-white rounded-lg transition-colors border border-slate-700 flex items-center gap-2",
                if(@conversations != [],
                  do: "hover:bg-red-900/50 hover:border-red-700 hover:text-red-200",
                  else: "opacity-50 cursor-not-allowed"
                )
              ]}
              title="Delete all conversations"
              id="clear-all-btn"
            >
              <.icon name="hero-trash" class="w-5 h-5" />
              <span class="text-sm">Clear All</span>
            </button>
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
                <div class="mt-2 space-y-3 max-h-96 overflow-y-auto">
                  <%!-- Server Status Section --%>
                  <%= if map_size(@mcp_server_status) > 0 do %>
                    <div class="px-3 py-2 bg-slate-900/50 rounded-lg border border-slate-700">
                      <div class="text-xs font-medium text-gray-300 mb-2">Server Status</div>
                      <div class="space-y-1">
                        <%= for {name, info} <- @mcp_server_status do %>
                          <div class="flex items-center justify-between text-xs">
                            <span class="text-gray-400">{info.display_name}</span>
                            <%= cond do %>
                              <% info.status == :connected -> %>
                                <div class="flex items-center gap-1">
                                  <span class="w-2 h-2 bg-green-500 rounded-full"></span>
                                  <span class="text-green-400">Connected</span>
                                  <%= if info.restart_count && info.restart_count > 0 do %>
                                    <span class="text-yellow-400 text-xs ml-1">
                                      (restarted {info.restart_count}x)
                                    </span>
                                  <% end %>
                                </div>
                              <% info.status == :restarting -> %>
                                <div class="flex items-center gap-1">
                                  <span class="w-2 h-2 bg-yellow-500 rounded-full animate-pulse">
                                  </span>
                                  <span class="text-yellow-400">Restarting...</span>
                                </div>
                              <% true -> %>
                                <div class="flex items-center gap-1">
                                  <span class="w-2 h-2 bg-red-500 rounded-full"></span>
                                  <span class="text-red-400">Disconnected</span>
                                </div>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                  <%!-- Tools Section --%>
                  <%= if map_size(@mcp_tools) == 0 do %>
                    <p class="text-sm text-gray-400 px-3 py-2">No MCP tools available</p>
                  <% else %>
                    <div class="px-3 py-1 text-xs font-medium text-gray-300">
                      Available Tools ({map_size(@mcp_tools)})
                    </div>
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
                        <span class="text-blue-400 font-mono">
                          {@generation_params["temperature"]}
                        </span>
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
                        <span class="text-blue-400 font-mono">
                          {@generation_params["num_predict"]}
                        </span>
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

          <%!-- Footer info (sidebar) --%>
          <div class="text-center text-sm text-slate-400 mt-6 hidden xl:block">
            <p>
              Powered by Ollama • Model:
              <span class="text-blue-400 font-medium">{@selected_model}</span>
            </p>
          </div>
        </div>

        <%!-- Main content (right column on wide screens) --%>
        <div class="xl:flex-1 xl:min-w-0 flex flex-col max-h-[calc(100vh-4rem)]">
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

          <%!-- Storage error display --%>
          <%= if @storage_error do %>
            <div class="mb-4 p-4 bg-yellow-900/50 border border-yellow-500 rounded-lg text-yellow-200">
              <div class="flex items-start gap-2">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5 mt-0.5 flex-shrink-0" />
                <div class="flex-1">
                  <p class="font-semibold">Storage Warning</p>
                  <p class="text-sm">{@storage_error}</p>
                </div>
                <button
                  type="button"
                  phx-click="dismiss_storage_error"
                  class="text-yellow-300 hover:text-yellow-100 transition-colors"
                  title="Dismiss"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>
            </div>
          <% end %>

          <%!-- Chat and input wrapper: Contains both the chat area (messages) and input area (compose) --%>
          <%!-- Layout: Chat area fills available space (flex-1), input area stays at bottom (flex-shrink-0) --%>
          <div class="flex-1 flex flex-col min-h-0">
            <%!-- Chat area: Scrollable message history (user and assistant messages) --%>
            <div class="bg-slate-800/50 rounded-t-xl shadow-2xl backdrop-blur-sm border border-slate-700 border-b-0 overflow-hidden flex flex-col flex-1 min-h-0">
              <div
                id="messages-container"
                phx-hook=".CopyMessage .ScrollToBottom"
                class="flex-1 overflow-y-auto p-6 space-y-4 relative min-h-[400px]"
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
                          <div class="text-white bg-slate-700/50 border border-slate-600 px-4 py-3 max-w-[80%] relative">
                            <p class="whitespace-pre-wrap break-words">{message.content}</p>
                            <button
                              type="button"
                              class="copy-btn absolute top-2 left-2 p-1 rounded text-cyan-400 hover:text-cyan-300 bg-black/30 hover:bg-black/50 opacity-0 group-hover:opacity-100 transition-all z-10"
                              title="Copy message"
                            >
                              <.icon
                                name="hero-clipboard-document"
                                class="w-4 h-4 copy-icon"
                              />
                              <.icon name="hero-check" class="w-4 h-4 check-icon hidden" />
                            </button>
                          </div>
                        </div>
                      <% message.role == "tool_error" -> %>
                        <div class="flex justify-start">
                          <div class="border border-red-700 px-4 py-3 max-w-[80%]">
                            <div class="flex items-center gap-2">
                              <span class="text-red-400 text-xs">&#x2716;</span>
                              <span class="text-sm text-red-300">
                                Tool failed: {message.tool_name}
                              </span>
                            </div>
                            <div class="text-xs text-red-400 mt-1">
                              {message.content}
                            </div>
                          </div>
                        </div>
                      <% empty_response?(message.content) and not message.streaming -> %>
                        <%!-- Hide empty intermediate responses entirely --%>
                        <div class="hidden"></div>
                      <% true -> %>
                        <div class="flex justify-start flex-col gap-2">
                          <%!-- Single collapsible intermediate activity container --%>
                          <%= if has_intermediate_events?(message, @streaming_message_id, @streaming_events) do %>
                            <div class="border border-slate-600 max-w-[80%]">
                              <div class="flex items-center gap-2 px-3 py-1">
                                <span class="text-xs text-slate-400 flex-1">
                                  <%= if message.streaming do %>
                                    {intermediate_event_count(message, @streaming_events)} intermediate events
                                  <% else %>
                                    {length(message.intermediate_events)} intermediate events
                                  <% end %>
                                </span>
                                <button
                                  type="button"
                                  phx-click="toggle_activity"
                                  class={[
                                    "px-1.5 py-0.5 rounded text-xs font-bold leading-none",
                                    "text-slate-300 hover:text-white transition-colors"
                                  ]}
                                  title={if @activity_expanded, do: "Collapse", else: "Expand"}
                                >
                                  <%= if @activity_expanded do %>
                                    &#x25BC;
                                  <% else %>
                                    &#x25B2;
                                  <% end %>
                                </button>
                              </div>
                              <%= if @activity_expanded do %>
                                <div class="px-3 py-2 border-t border-slate-600 space-y-2 max-h-96 overflow-y-auto">
                                  <%= for event <- intermediate_events_list(message, @streaming_events) do %>
                                    <%= cond do %>
                                      <% event.type == :chunk -> %>
                                        <div class="text-xs text-slate-300 border-l border-slate-600 pl-3 py-1">
                                          <div class="whitespace-pre-wrap break-words">
                                            {event.content}
                                          </div>
                                        </div>
                                      <% event.type == :tool_call -> %>
                                        <div class="text-xs border-l border-blue-600 pl-3 py-1">
                                          <div class="text-blue-400 mb-1">
                                            Calling tool:
                                            <span class="font-mono">{event.tool_name}</span>
                                          </div>
                                          <%= if event[:args] && map_size(event.args) > 0 do %>
                                            <pre class="text-xs text-blue-300 bg-slate-900/50 p-1 mt-1">{inspect(event.args, pretty: true, limit: 3)}</pre>
                                          <% end %>
                                        </div>
                                      <% event.type == :tool_result -> %>
                                        <div class="text-xs border-l border-green-600 pl-3 py-1">
                                          <div class="text-green-400 mb-1">
                                            Tool completed:
                                            <span class="font-mono">{event.tool_name}</span>
                                          </div>
                                          <pre class="text-xs text-green-300 bg-slate-900/50 p-1 mt-1 max-h-20 overflow-y-auto">{String.slice(event.content, 0, 200)}<%= if String.length(event.content) > 200, do: "..." %></pre>
                                        </div>
                                      <% true -> %>
                                        <div class="text-xs text-slate-400 italic">
                                          {event.content}
                                        </div>
                                    <% end %>
                                  <% end %>
                                </div>
                              <% end %>
                            </div>
                          <% end %>

                          <%!-- Main streaming/final response --%>
                          <div class="text-white border border-slate-600 px-4 py-3 max-w-[80%] relative">
                            <%= if message.streaming do %>
                              <p class="whitespace-pre-wrap break-words">{message.content}</p>
                              <span class="inline-block w-2 h-4 bg-white ml-1 animate-pulse"></span>
                            <% else %>
                              <div class="prose-chat">{raw(message.html_content)}</div>
                              <button
                                type="button"
                                class="copy-btn absolute top-2 right-2 p-1 rounded text-slate-400 hover:text-white opacity-0 group-hover:opacity-100 transition-opacity"
                                title="Copy message"
                              >
                                <.icon
                                  name="hero-clipboard-document"
                                  class="w-4 h-4 copy-icon"
                                />
                                <.icon name="hero-check" class="w-4 h-4 check-icon hidden" />
                              </button>
                            <% end %>
                          </div>
                        </div>
                    <% end %>
                  </div>
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

            <%!-- Input area: Message composer with textarea, Attach and Send buttons --%>
            <div class="bg-slate-800/50 rounded-b-xl shadow-2xl backdrop-blur-sm border border-slate-700 border-t-0 p-4 flex-shrink-0">
              <%!-- Context attachments display --%>
              <%= if length(@context_attachments) > 0 do %>
                <div class="mb-3 p-3 bg-blue-900/20 rounded-lg border border-blue-700/50">
                  <div class="flex items-center justify-between mb-2">
                    <div class="text-sm text-blue-300 flex items-center gap-2">
                      <.icon name="hero-document-duplicate" class="w-4 h-4" />
                      <span>
                        Context ({length(@context_attachments)} file{if length(@context_attachments) !=
                                                                          1,
                                                                        do: "s"})
                      </span>
                    </div>
                    <button
                      type="button"
                      phx-click="clear_all_context"
                      class="text-xs text-blue-400 hover:text-blue-300 transition-colors"
                    >
                      Clear All
                    </button>
                  </div>
                  <div class="space-y-1">
                    <%= for {attachment, index} <- Enum.with_index(@context_attachments) do %>
                      <div class="flex items-center gap-2 p-2 bg-blue-900/30 rounded text-xs">
                        <.icon name="hero-document-text" class="w-4 h-4 text-blue-400 flex-shrink-0" />
                        <div class="flex-1 min-w-0">
                          <span class="text-blue-200 truncate">{attachment.name}</span>
                          <span class="text-blue-400 ml-2">
                            ({format_file_size(attachment.size)})
                          </span>
                        </div>
                        <button
                          type="button"
                          phx-click="remove_context_attachment"
                          phx-value-index={index}
                          class="p-1 text-blue-400 hover:text-red-400 transition-colors"
                        >
                          <.icon name="hero-x-mark" class="w-3 h-3" />
                        </button>
                      </div>
                    <% end %>
                  </div>
                  <div class="mt-2 text-xs text-blue-400">
                    These files will be included as context in all your messages until removed.
                  </div>
                </div>
              <% end %>

              <.form for={@form} id="chat-form" phx-submit="send" phx-change="validate">
                <%!-- File upload area for new attachments --%>
                <%= if length(@uploads.files.entries) > 0 or length(@attachments) > 0 do %>
                  <div class="mb-3 p-3 bg-slate-900/50 rounded-lg border border-slate-600">
                    <div class="text-sm text-slate-400 mb-2 flex items-center gap-2">
                      <.icon name="hero-paper-clip" class="w-4 h-4" />
                      <span>New Attachments (will be added to context)</span>
                    </div>
                    <div class="space-y-2">
                      <%!-- Show uploaded files --%>
                      <%= for entry <- @uploads.files.entries do %>
                        <div class="flex items-center gap-2 p-2 bg-slate-800 rounded">
                          <.icon
                            name="hero-document-text"
                            class="w-5 h-5 text-blue-400 flex-shrink-0"
                          />
                          <div class="flex-1 min-w-0">
                            <div class="text-sm text-white truncate">{entry.client_name}</div>
                            <div class="text-xs text-slate-400">
                              {format_file_size(entry.client_size)}
                              <%= if entry.progress > 0 and entry.progress < 100 do %>
                                • Uploading {entry.progress}%
                              <% end %>
                            </div>
                          </div>
                          <button
                            type="button"
                            phx-click="cancel_upload"
                            phx-value-ref={entry.ref}
                            class="p-1 text-slate-400 hover:text-red-400 transition-colors"
                          >
                            <.icon name="hero-x-mark" class="w-4 h-4" />
                          </button>
                        </div>
                      <% end %>
                      <%!-- Show existing attachments --%>
                      <%= for attachment <- @attachments do %>
                        <div class="flex items-center gap-2 p-2 bg-slate-800 rounded">
                          <.icon
                            name="hero-document-text"
                            class="w-5 h-5 text-green-400 flex-shrink-0"
                          />
                          <div class="flex-1 min-w-0">
                            <div class="text-sm text-white truncate">{attachment.name}</div>
                            <div class="text-xs text-slate-400">
                              {format_file_size(attachment.size)}
                            </div>
                          </div>
                          <button
                            type="button"
                            phx-click="remove_attachment"
                            phx-value-ref={attachment.ref}
                            class="p-1 text-slate-400 hover:text-red-400 transition-colors"
                          >
                            <.icon name="hero-x-mark" class="w-4 h-4" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <div class="flex gap-3 items-end">
                  <div class="flex-1 max-w-full overflow-auto max-h-[500px] relative group">
                    <.input
                      field={@form[:message]}
                      type="textarea"
                      placeholder="Type your message... (Enter to send, Shift+Enter for new line)"
                      autocomplete="off"
                      disabled={@loading}
                      rows="4"
                      phx-hook=".PreventEnterSubmit"
                      class="w-full bg-slate-900 text-white border-slate-600 focus:border-blue-500 focus:ring-blue-500 resize-y min-h-[100px] px-4 py-3 pr-12"
                    />
                    <%= if @form[:message].value && String.trim(@form[:message].value) != "" do %>
                      <button
                        type="button"
                        id="copy-prompt-btn"
                        phx-hook=".CopyPrompt"
                        data-prompt={@form[:message].value}
                        class="absolute top-2 right-2 p-2 rounded text-cyan-400 hover:text-cyan-300 bg-slate-800 hover:bg-slate-900 transition-all z-10"
                        title="Copy prompt"
                      >
                        <.icon name="hero-clipboard-document" class="w-4 h-4 copy-icon" />
                        <.icon name="hero-check" class="w-4 h-4 check-icon hidden" />
                      </button>
                    <% end %>
                  </div>
                  <div class="flex flex-col gap-2 flex-shrink-0">
                    <%!-- File upload button --%>
                    <label
                      for={@uploads.files.ref}
                      class="flex items-center justify-center gap-2 px-6 py-3 rounded-lg font-medium transition-all duration-200 bg-slate-700 hover:bg-slate-600 text-white cursor-pointer"
                    >
                      <.icon name="hero-paper-clip" class="w-5 h-5" />
                      <span>Attach</span>
                      <.live_file_input upload={@uploads.files} class="hidden" />
                    </label>
                    <%= if @loading do %>
                      <button
                        type="button"
                        phx-click="cancel_stream"
                        class={[
                          "px-6 py-3 rounded-lg font-medium transition-all duration-200",
                          "bg-red-600 hover:bg-red-700 text-white",
                          "flex items-center justify-center gap-2"
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
                          "flex items-center justify-center gap-2"
                        ]}
                      >
                        <.icon name="hero-paper-airplane" class="w-5 h-5" />
                        <span>Send</span>
                      </button>
                    <% end %>
                  </div>
                </div>

                <%!-- Upload errors --%>
                <%= for err <- upload_errors(@uploads.files) do %>
                  <div class="mt-2 text-sm text-red-400">
                    {error_to_string(err)}
                  </div>
                <% end %>
              </.form>
            </div>
          </div>

          <%!-- Footer info (mobile only, shown below chat on small screens) --%>
          <div class="text-center text-sm text-slate-400 xl:hidden">
            <p>
              Powered by Ollama • Model:
              <span class="text-blue-400 font-medium">{@selected_model}</span>
            </p>
          </div>
        </div>
      </div>
    </div>

    <%!-- Auto-scroll to bottom hook --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
      export default {
        mounted() {
          this.scrollToBottom();
          this.setupObserver();
        },
        updated() {
          this.scrollToBottom();
        },
        destroyed() {
          if (this.observer) {
            this.observer.disconnect();
          }
        },
        setupObserver() {
          // Find the #messages div that contains the actual message stream
          const messagesDiv = this.el.querySelector('#messages');
          if (!messagesDiv) return;

          // Watch for new messages being added to the DOM
          this.observer = new MutationObserver((mutations) => {
            // Check if new child elements were added
            const hasNewNodes = mutations.some(mutation => mutation.addedNodes.length > 0);
            if (hasNewNodes) {
              this.scrollToBottom();
            }
          });

          // Observe the messages stream div for changes to its children
          this.observer.observe(messagesDiv, {
            childList: true,
            subtree: false
          });
        },
        scrollToBottom() {
          // Only auto-scroll if user is near the bottom (within 100px)
          const isNearBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 100;

          if (isNearBottom) {
            // Use requestAnimationFrame for smooth scrolling
            requestAnimationFrame(() => {
              this.el.scrollTop = this.el.scrollHeight;
            });
          }
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

    <%!-- Enter submits, Shift+Enter inserts newline --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PreventEnterSubmit">
      export default {
        mounted() {
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              // Submit the parent form
              const form = this.el.closest("form");
              if (form) {
                form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
              }
            }
          });
        }
      }
    </script>

    <%!-- Copy prompt to clipboard hook --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyPrompt">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const content = this.el.getAttribute("data-prompt");
            if (!content) return;

            navigator.clipboard.writeText(content).then(() => {
              const copyIcon = this.el.querySelector(".copy-icon");
              const checkIcon = this.el.querySelector(".check-icon");
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
        },
        updated() {
          // Update data attribute when prompt changes
          const textarea = document.querySelector("textarea[name='message']");
          if (textarea) {
            this.el.setAttribute("data-prompt", textarea.value);
          }
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

          // Listen for delete conversation events
          this.handleEvent("delete_conversation", (data) => {
            this.deleteConversation(data.conversation_id);
            this.loadConversations();
            this.pushEvent("conversation_deleted", { conversation_id: data.conversation_id });
          });

          // Listen for clear all conversations events
          this.handleEvent("clear_all_conversations", () => {
            try {
              localStorage.setItem(this.storageKey, JSON.stringify([]));
            } catch (e) {
              console.error("Error clearing conversations:", e);
            }
            this.loadConversations();
            this.pushEvent("all_conversations_cleared", {});
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

        deleteConversation(id) {
          try {
            const conversations = this.getConversations().filter(c => c.id !== id);
            localStorage.setItem(this.storageKey, JSON.stringify(conversations));
          } catch (e) {
            console.error("Error deleting conversation:", e);
            this.pushEvent("storage_error", { message: "Failed to delete conversation." });
          }
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
    |> assign(:streaming_events, [])
    |> assign(:activity_expanded, false)
    |> assign(:streaming_message_id, nil)
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
    |> assign(:context_attachments, [])
    |> assign(:attachments, [])
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
    # Add tool call to streaming events instead of separate message
    current_events = socket.assigns.streaming_events

    updated_events =
      current_events ++
        [
          %{
            type: :tool_call,
            tool_name: tool_name,
            args: args,
            timestamp: DateTime.utc_now()
          }
        ]

    socket = assign(socket, :streaming_events, updated_events)

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
      streaming: true,
      intermediate_events: []
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
      |> assign(:streaming_events, socket.assigns.streaming_events)
      |> assign(:streaming_message_id, continuation_message_id)
      |> assign(:loading, true)
      |> assign(:streaming_pid, pid)

    socket
  end

  defp empty_response?(content) when is_binary(content) do
    trimmed = String.trim(content)
    trimmed == "" or String.replace(trimmed, "`", "") == ""
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

  defp read_attachments(attachments) do
    Enum.map(attachments, fn att ->
      case File.read(att.path) do
        {:ok, content} ->
          %{
            name: att.name,
            content: content,
            type: att.content_type,
            size: att.size
          }

        {:error, _} ->
          %{
            name: att.name,
            content: "[Error reading file]",
            type: att.content_type,
            size: att.size
          }
      end
    end)
  end

  defp has_intermediate_events?(message, streaming_message_id, streaming_events) do
    cond do
      # During streaming: check live streaming events
      message.id == streaming_message_id and message.streaming ->
        length(streaming_events) > 1

      # After streaming: check persisted events on the message
      not message.streaming and is_list(Map.get(message, :intermediate_events)) ->
        length(message.intermediate_events) > 0

      true ->
        false
    end
  end

  defp intermediate_events_list(message, streaming_events) do
    if message.streaming do
      # During streaming: show all events except the last (current) chunk
      Enum.slice(streaming_events, 0..(length(streaming_events) - 2)//1)
    else
      Map.get(message, :intermediate_events, [])
    end
  end

  defp intermediate_event_count(message, streaming_events) do
    if message.streaming do
      max(length(streaming_events) - 1, 0)
    else
      length(Map.get(message, :intermediate_events, []))
    end
  end

  defp build_message_with_attachments(message, []) do
    message
  end

  defp build_message_with_attachments(message, attachment_contents) do
    context_header = """

    [CONTEXT FILES - These files are provided as reference for this conversation]
    """

    attachments_text =
      attachment_contents
      |> Enum.map(fn att ->
        """

        --- File: #{att.name} (#{format_file_size(att.size)}) ---
        #{att.content}
        --- End of #{att.name} ---
        """
      end)
      |> Enum.join("\n")

    full_context = context_header <> attachments_text <> "\n[END OF CONTEXT FILES]\n"

    if message == "" do
      "Please analyze the provided context files." <> full_context
    else
      message <> "\n" <> full_context
    end
  end

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_file_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)}KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1024 / 1024, 2)}MB"

  defp error_to_string(:too_large), do: "File is too large (max 10MB)"
  defp error_to_string(:not_accepted), do: "File type not accepted"
  defp error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp error_to_string(err), do: "Upload error: #{inspect(err)}"

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

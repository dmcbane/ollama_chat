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

  alias OllamaChat.{
    Markdown,
    MCPClient,
    MCPPromptBuilder,
    MCPResponseParser,
    Memory,
    OllamaClient,
    ToolPromptBuilder,
    ToolRouter
  }

  alias OllamaChat.BuiltinTools.Registry, as: BuiltinRegistry
  alias OllamaChat.Memory.Extractor, as: MemoryExtractor

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
      |> assign(
        :streaming_model,
        Application.get_env(:ollama_chat, :ollama_default_model, "llama3")
      )
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
      |> assign(:show_storage_settings, false)
      |> assign(:save_intermediate_events, false)
      |> assign(:show_settings, false)
      |> assign(:settings_tab, :general)
      |> assign(:mcp_server_configs, [])
      |> assign(:editing_mcp_server, nil)
      |> assign(:mcp_form_error, nil)
      |> assign(:health_check_enabled, OllamaClient.health_check_enabled?())
      |> assign(:health_check_healthy, true)
      |> assign(:health_check_timer, nil)
      |> assign(:streaming_pid, nil)
      |> assign(:toast_message, nil)
      |> assign(:toast_type, nil)
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

    socket =
      if connected?(socket) do
        send(self(), :check_ollama_status)
        send(self(), :load_models)

        # Schedule health checks independently of MCP
        if OllamaClient.health_check_enabled?() do
          timer = Process.send_after(self(), :health_check, OllamaClient.health_check_interval())
          assign(socket, :health_check_timer, timer)
        else
          socket
        end
      else
        socket
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
        intermediate_events: [],
        model: socket.assigns.selected_model
      }

      # Build conversation history
      messages_for_api =
        [user_message | socket.assigns.message_history]
        |> Enum.reverse()
        |> Enum.map(fn msg ->
          # message_history can contain atom-keyed maps (created this session)
          # or string-keyed maps (loaded from a saved conversation via localStorage JSON)
          %{
            role: msg[:role] || msg["role"],
            content: msg[:content] || msg["content"]
          }
        end)

      # Build system prompt (tool-aware: includes built-in memory tools + MCP tools)
      system_prompt =
        if ToolPromptBuilder.any_tools_available?(socket.assigns.mcp_tools) do
          ToolPromptBuilder.build_tool_aware_system_prompt(
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

      # Retrieve relevant memories and inject into system prompt (Phase 3)
      memory_context = retrieve_memory_context(message)

      system_prompt =
        case {system_prompt, Memory.format_for_prompt(memory_context)} do
          {base, nil} -> base
          {nil, mem_section} -> mem_section
          {base, mem_section} -> base <> "\n\n" <> mem_section
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
        |> assign(:streaming_model, socket.assigns.selected_model)
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
    Logger.debug(
      "Model selected: #{inspect(model)} (was: #{inspect(socket.assigns.selected_model)})"
    )

    socket = push_event(socket, "save_model_preference", %{model: model})
    {:noreply, assign(socket, :selected_model, model)}
  end

  @impl true
  def handle_event("model_preference_loaded", %{"model" => saved_model}, socket) do
    selected =
      if saved_model in socket.assigns.available_models do
        saved_model
      else
        socket.assigns.selected_model
      end

    {:noreply, assign(socket, :selected_model, selected)}
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
      |> assign(:selected_model, conversation["model"] || socket.assigns.selected_model)
      |> assign(:message_history, messages)
      |> assign(:messages_empty?, messages == [])
      |> assign(:system_prompt, conversation["system_prompt"] || "")
      |> assign(
        :generation_params,
        restore_generation_params(conversation["generation_params"])
      )

    socket = push_event(socket, "save_model_preference", %{model: socket.assigns.selected_model})

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
  def handle_event("restart_ollama", _params, socket) do
    socket =
      socket
      |> assign(:status_message, "Restarting Ollama...")
      |> assign(:recovering, true)
      |> assign(:ollama_status, :unknown)

    # Cancel any current stream
    if socket.assigns.streaming_pid do
      Process.exit(socket.assigns.streaming_pid, :kill)
    end

    # Start restart in background
    parent = self()

    spawn(fn ->
      case OllamaClient.restart_ollama() do
        :ok ->
          send(parent, {:restart_success})

        {:error, reason} ->
          send(parent, {:restart_failed, reason})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("kill_ollama", _params, socket) do
    socket =
      socket
      |> assign(:status_message, "Killing Ollama process...")
      |> assign(:ollama_status, :unknown)

    # Cancel any current stream
    if socket.assigns.streaming_pid do
      Process.exit(socket.assigns.streaming_pid, :kill)
    end

    # Kill in background
    parent = self()

    spawn(fn ->
      case OllamaClient.kill_ollama() do
        :ok ->
          send(parent, {:kill_success})

        {:error, reason} ->
          send(parent, {:kill_failed, reason})
      end
    end)

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
  def handle_event("toggle_storage_settings", _params, socket) do
    {:noreply, assign(socket, :show_storage_settings, !socket.assigns.show_storage_settings)}
  end

  @impl true
  def handle_event("open_settings", _params, socket) do
    socket =
      if socket.assigns.mcp_enabled? do
        server_status = MCPClient.server_info()
        configs = MCPClient.list_server_configs()

        socket
        |> assign(:mcp_server_status, server_status)
        |> assign(:mcp_server_configs, configs)
      else
        socket
      end

    {:noreply, assign(socket, :show_settings, true)}
  end

  @impl true
  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  @impl true
  def handle_event("switch_settings_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    {:noreply, assign(socket, :settings_tab, tab_atom)}
  end

  @impl true
  def handle_event("add_mcp_server", _params, socket) do
    new_server = %{
      "name" => "",
      "display_name" => "",
      "description" => "",
      "command" => "",
      "args" => "",
      "enabled" => true,
      "requires_approval" => false,
      "dangerous_tools" => ""
    }

    {:noreply,
     socket
     |> assign(:editing_mcp_server, new_server)
     |> assign(:mcp_form_error, nil)}
  end

  @impl true
  def handle_event("edit_mcp_server", %{"name" => name}, socket) do
    name_atom = String.to_atom(name)

    case Enum.find(socket.assigns.mcp_server_configs, fn s -> s.name == name_atom end) do
      nil ->
        {:noreply, assign(socket, :mcp_form_error, "Server not found")}

      config ->
        form_data = %{
          "name" => to_string(config.name),
          "display_name" => config.display_name,
          "description" => Map.get(config, :description, ""),
          "command" => config.command,
          "args" => Enum.join(Map.get(config, :args, []), "\n"),
          "enabled" => Map.get(config, :enabled, true),
          "requires_approval" => Map.get(config, :requires_approval, false),
          "dangerous_tools" => Enum.join(Map.get(config, :dangerous_tools, []), ", ")
        }

        {:noreply,
         socket
         |> assign(:editing_mcp_server, form_data)
         |> assign(:mcp_form_error, nil)}
    end
  end

  @impl true
  def handle_event("cancel_edit_mcp_server", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_mcp_server, nil)
     |> assign(:mcp_form_error, nil)}
  end

  @impl true
  def handle_event("save_mcp_server", params, socket) do
    # Parse form data into server config
    args =
      params["args"]
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    dangerous_tools =
      params["dangerous_tools"]
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config = %{
      name: String.to_atom(String.trim(params["name"])),
      display_name: String.trim(params["display_name"]),
      description: String.trim(params["description"] || ""),
      command: String.trim(params["command"]),
      args: args,
      enabled: params["enabled"] == "true",
      requires_approval: params["requires_approval"] == "true",
      dangerous_tools: dangerous_tools
    }

    # Determine if this is an add or update by checking the actual MCPClient state
    # (not local assigns, which may be stale if MCP was disabled when settings opened)
    current_configs = MCPClient.list_server_configs()
    existing = Enum.find(current_configs, fn s -> s.name == config.name end)

    result =
      if existing do
        MCPClient.update_server(config.name, config)
      else
        MCPClient.add_server(config)
      end

    case result do
      :ok ->
        configs = MCPClient.list_server_configs()
        server_status = MCPClient.server_info()

        # Check command path and show appropriate toast
        command = String.trim(params["command"])

        toast_socket =
          case OllamaChat.MCPConfig.validate_command_path(command) do
            :ok ->
              show_toast(socket, "Server saved successfully")

            {:warning, warning} ->
              show_toast(socket, "Server saved — #{warning}", :warning)

            {:error, _} ->
              show_toast(socket, "Server saved successfully")
          end

        {:noreply,
         toast_socket
         |> assign(:mcp_server_configs, configs)
         |> assign(:mcp_server_status, server_status)
         |> assign(:mcp_tools, fetch_mcp_tools())
         |> assign(:editing_mcp_server, nil)
         |> assign(:mcp_form_error, nil)}

      {:error, {:validation, errors}} ->
        {:noreply, assign(socket, :mcp_form_error, Enum.join(errors, ". "))}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :mcp_form_error, message)}

      {:error, reason} ->
        {:noreply, assign(socket, :mcp_form_error, inspect(reason))}
    end
  end

  @impl true
  def handle_event("delete_mcp_server", %{"name" => name}, socket) do
    name_atom = String.to_atom(name)

    case MCPClient.remove_server(name_atom) do
      :ok ->
        configs = MCPClient.list_server_configs()
        server_status = MCPClient.server_info()

        {:noreply,
         socket
         |> show_toast("Server removed successfully")
         |> assign(:mcp_server_configs, configs)
         |> assign(:mcp_server_status, server_status)
         |> assign(:mcp_tools, fetch_mcp_tools())
         |> assign(:editing_mcp_server, nil)
         |> assign(:mcp_form_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :mcp_form_error, inspect(reason))}
    end
  end

  @impl true
  def handle_event("toggle_mcp_server_enabled", %{"name" => name}, socket) do
    name_atom = String.to_atom(name)

    case Enum.find(socket.assigns.mcp_server_configs, fn s -> s.name == name_atom end) do
      nil ->
        {:noreply, socket}

      config ->
        new_enabled = !config.enabled

        case MCPClient.toggle_server(name_atom, new_enabled) do
          :ok ->
            configs = MCPClient.list_server_configs()
            server_status = MCPClient.server_info()
            action = if new_enabled, do: "enabled", else: "disabled"

            {:noreply,
             socket
             |> show_toast("Server #{action} successfully")
             |> assign(:mcp_server_configs, configs)
             |> assign(:mcp_server_status, server_status)
             |> assign(:mcp_tools, fetch_mcp_tools())}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event("toggle_save_intermediate_events", _params, socket) do
    new_value = !socket.assigns.save_intermediate_events
    socket = assign(socket, :save_intermediate_events, new_value)
    # Push to localStorage via JavaScript hook
    {:noreply, push_event(socket, "save_preference", %{save_intermediate_events: new_value})}
  end

  @impl true
  def handle_event("preference_loaded", %{"save_intermediate_events" => value}, socket) do
    {:noreply, assign(socket, :save_intermediate_events, value)}
  end

  @impl true
  def handle_event("dismiss_toast", _params, socket) do
    {:noreply, socket |> assign(:toast_message, nil) |> assign(:toast_type, nil)}
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
        current_model = socket.assigns.selected_model
        selected = if current_model in models, do: current_model, else: List.first(models)

        {:noreply,
         socket
         |> assign(:available_models, models)
         |> assign(:selected_model, selected)
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
      intermediate_events:
        if(socket.assigns.save_intermediate_events, do: intermediate, else: []),
      model: socket.assigns.streaming_model
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

  @impl true
  def handle_info({:restart_success}, socket) do
    socket =
      socket
      |> assign(:status_message, "Ollama restarted successfully")
      |> assign(:recovering, false)
      |> assign(:ollama_status, :running)
      |> assign(:loading, false)
      |> assign(:streaming_message, "")
      |> assign(:streaming_message_id, nil)

    # Clear status message after a delay
    Process.send_after(self(), :clear_status, 3000)

    # Reload models
    send(self(), :load_models)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:restart_failed, reason}, socket) do
    socket =
      socket
      |> assign(:status_message, nil)
      |> assign(:recovering, false)
      |> assign(:ollama_status, :stopped)
      |> assign(:error, "Failed to restart Ollama: #{reason}")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:kill_success}, socket) do
    socket =
      socket
      |> assign(:status_message, "Ollama process killed")
      |> assign(:ollama_status, :stopped)
      |> assign(:loading, false)
      |> assign(:streaming_message, "")
      |> assign(:streaming_message_id, nil)

    # Clear status message after a delay
    Process.send_after(self(), :clear_status, 3000)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:kill_failed, reason}, socket) do
    socket =
      socket
      |> assign(:status_message, nil)
      |> assign(:error, "Failed to kill Ollama: #{reason}")

    {:noreply, socket}
  end

  # Built-in Tool Call Handlers

  @impl true
  def handle_info({:builtin_tool_result, message_id, tool_name, result_text}, socket) do
    Logger.info("Built-in tool #{tool_name} completed: #{String.slice(result_text, 0, 80)}")

    # Show a toast notification when the LLM saves a memory
    socket =
      if tool_name == "memory_save" do
        show_toast(socket, "Memory saved", :success)
      else
        socket
      end

    # Add tool result to streaming events
    updated_events =
      socket.assigns.streaming_events ++
        [
          %{
            type: :tool_result,
            tool_name: tool_name,
            content: result_text,
            timestamp: DateTime.utc_now()
          }
        ]

    socket = assign(socket, :streaming_events, updated_events)

    # Wrap the plain-text result in a content list so continue_with_tool_result
    # can format it identically to MCP tool results.
    result_as_content = [%{"type" => "text", "text" => result_text}]
    socket = continue_with_tool_result(socket, message_id, tool_name, result_as_content)

    {:noreply, socket}
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
  def handle_info(:refresh_mcp_status, socket) do
    if socket.assigns.mcp_enabled? do
      server_status = MCPClient.server_info()

      # Also refresh tools in case they weren't available at mount time
      # (tool discovery runs ~1s after server startup)
      socket =
        case MCPClient.list_tools() do
          {:ok, tools} when tools != %{} ->
            assign(socket, :mcp_tools, tools)

          _ ->
            socket
        end

      # Schedule next update
      Process.send_after(self(), :refresh_mcp_status, 10_000)

      {:noreply, assign(socket, :mcp_server_status, server_status)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:health_check, socket) do
    healthy = OllamaClient.ollama_running?()
    was_healthy = socket.assigns.health_check_healthy

    if was_healthy and not healthy do
      Logger.warning("Health check: Ollama became unreachable")
    end

    if not was_healthy and healthy do
      Logger.info("Health check: Ollama is reachable again")
    end

    # Schedule next check
    timer = Process.send_after(self(), :health_check, OllamaClient.health_check_interval())

    {:noreply,
     socket
     |> assign(:health_check_healthy, healthy)
     |> assign(:health_check_timer, timer)}
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
  def handle_info(:clear_toast, socket) do
    {:noreply, socket |> assign(:toast_message, nil) |> assign(:toast_type, nil)}
  end

  defp show_toast(socket, message, type \\ :success) do
    Process.send_after(self(), :clear_toast, 3000)

    socket
    |> assign(:toast_message, message)
    |> assign(:toast_type, type)
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
      intermediate_events: [],
      model: socket.assigns.streaming_model
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
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-900 via-blue-900 to-slate-900">
      <div class="mx-auto max-w-7xl px-4 py-8 xl:flex xl:gap-6">
        <%!-- Sidebar (left column on wide screens) --%>
        <div class="xl:w-80 xl:flex-shrink-0 xl:sticky xl:top-8 xl:self-start xl:max-h-[calc(100vh-4rem)] xl:overflow-y-auto mb-6 xl:mb-0">
          <%!-- Header --%>
          <div class="mb-4">
            <h1 class="text-4xl font-bold text-white">Ollama Chat</h1>
          </div>

          <%!-- Status indicators (Ollama + MCP — unified row) --%>
          <div class="flex items-center gap-2 mb-4">
            <%!-- Ollama status (combines connection + health check) --%>
            <% {ollama_dot, ollama_label, ollama_text_cls, ollama_bg_cls} =
              ollama_status_display(assigns) %>
            <div
              class={[
                "flex-1 px-3 py-2 rounded-lg flex items-center gap-2 border",
                ollama_bg_cls
              ]}
              title={ollama_status_tooltip(assigns)}
              id="ollama-status-indicator"
            >
              <div class={"w-2 h-2 rounded-full flex-shrink-0 " <> ollama_dot}></div>
              <span class={"text-xs " <> ollama_text_cls}>
                {ollama_label}
              </span>
            </div>
            <%!-- MCP tools --%>
            <%= if @mcp_enabled? do %>
              <div
                class="flex-1 px-3 py-2 bg-slate-800/60 rounded-lg border border-slate-700/50 flex items-center gap-2"
                title={mcp_status_tooltip(assigns)}
                id="mcp-status-indicator"
              >
                <.icon
                  name="hero-wrench-screwdriver"
                  class={[
                    "w-3.5 h-3.5 flex-shrink-0",
                    if(map_size(@mcp_tools) > 0, do: "text-purple-400", else: "text-gray-500")
                  ]}
                />
                <span class={[
                  "text-xs",
                  if(map_size(@mcp_tools) > 0, do: "text-gray-400", else: "text-gray-500")
                ]}>
                  <%= if map_size(@mcp_tools) > 0 do %>
                    {map_size(@mcp_tools)} tools
                  <% else %>
                    No tools
                  <% end %>
                </span>
              </div>
            <% end %>
          </div>

          <%!-- Ollama Server controls --%>
          <%= if @start_command_configured do %>
            <div class="mb-4">
              <label class="text-sm text-gray-300 mb-1 block">Server</label>
              <div class="flex items-center gap-2">
                <%= if @ollama_status == :stopped and not @recovering do %>
                  <button
                    phx-click="start_ollama"
                    id="start-ollama-btn"
                    class="px-4 py-2 bg-slate-800 text-white rounded-lg transition-colors border border-slate-700 flex items-center gap-2 hover:bg-green-900/50 hover:border-green-700 hover:text-green-200"
                    title="Start the Ollama process"
                  >
                    <.icon name="hero-play" class="w-5 h-5" />
                    <span class="text-sm">Start Ollama</span>
                  </button>
                <% end %>
                <%= if @ollama_status == :running do %>
                  <button
                    phx-click="restart_ollama"
                    id="restart-ollama-btn"
                    class="px-4 py-2 bg-slate-800 text-white rounded-lg transition-colors border border-slate-700 flex items-center gap-2 hover:bg-yellow-900/50 hover:border-yellow-700 hover:text-yellow-200"
                    title="Restart Ollama — useful for clearing stuck or runaway responses"
                  >
                    <.icon name="hero-arrow-path" class="w-5 h-5" />
                    <span class="text-sm">Restart</span>
                  </button>
                  <button
                    phx-click="kill_ollama"
                    id="kill-ollama-btn"
                    class="px-4 py-2 bg-slate-800 text-white rounded-lg transition-colors border border-slate-700 flex items-center gap-2 hover:bg-red-900/50 hover:border-red-700 hover:text-red-200"
                    title="Kill the Ollama process immediately"
                  >
                    <.icon name="hero-x-circle" class="w-5 h-5" />
                    <span class="text-sm">Kill</span>
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Model selector (styled to match conversations container) --%>
          <%= if @available_models != [] do %>
            <div class="mb-4">
              <div class="bg-slate-800 rounded-lg border border-slate-700 overflow-hidden">
                <div class="flex items-center gap-2 px-3">
                  <.icon name="hero-cpu-chip" class="w-4 h-4 text-gray-400 flex-shrink-0" />
                  <select
                    id="model-select"
                    class="flex-1 bg-transparent text-white text-sm py-2.5 border-0 focus:ring-0 focus:outline-none cursor-pointer appearance-none"
                    phx-hook=".ModelSelector"
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
                  <.icon
                    name="hero-chevron-up-down"
                    class="w-4 h-4 text-gray-500 flex-shrink-0 pointer-events-none"
                  />
                </div>
              </div>
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
          <div class="flex flex-wrap items-center gap-2 mb-4">
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

            <%!-- Settings button (same style as Export / Clear All) --%>
            <button
              type="button"
              phx-click="open_settings"
              id="open-settings-btn"
              class="group px-4 py-2 bg-slate-800 hover:bg-slate-700 text-white rounded-lg transition-colors border border-slate-700 flex items-center gap-2"
              title={settings_button_tooltip(assigns)}
            >
              <.icon name="hero-cog-6-tooth" class="w-5 h-5 animate-gear-hover" />
              <span class="text-sm">Settings</span>
              <%= if @system_prompt != "" or generation_params_customized?(@generation_params) do %>
                <span class="w-2 h-2 rounded-full bg-blue-500 flex-shrink-0" />
              <% end %>
            </button>
          </div>

          <%!-- Hidden hook for loading storage preferences at mount --%>
          <div id="storage-settings" class="hidden" phx-hook=".StorageSettings"></div>

          <%!-- Footer info (sidebar) --%>
          <div class="text-center text-sm text-slate-400 mt-6 hidden xl:block">
            <p>
              Powered by Ollama • Model:
              <span class="text-blue-400 font-medium">{@selected_model}</span>
            </p>
          </div>
        </div>

        <%!-- Main content (right column on wide screens) --%>
        <div class="xl:flex-1 xl:min-w-0 flex flex-col xl:h-[calc(100vh-4rem)]">
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
          <div class="flex-1 flex flex-col min-h-0 min-h-[600px] xl:min-h-0">
            <%!-- Chat area: Scrollable message history (user and assistant messages) --%>
            <div class="bg-slate-800/50 rounded-t-xl shadow-2xl backdrop-blur-sm border border-slate-700 border-b-0 overflow-hidden flex-1 flex flex-col min-h-0">
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
                              <%= if message[:model] do %>
                                <div class="mt-2 pt-2 border-t border-slate-700/50 flex items-center gap-1">
                                  <.icon name="hero-cpu-chip" class="w-3 h-3 text-slate-500" />
                                  <span class="text-xs text-slate-500 font-mono">
                                    {message[:model]}
                                  </span>
                                </div>
                              <% end %>
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

            <%!-- Settings Dialog --%>
            <%= if @show_settings do %>
              <div
                class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center z-50 p-4 animate-dialog-overlay"
                phx-click="close_settings"
                phx-window-keydown="close_settings"
                phx-key="Escape"
                id="settings-overlay"
                role="dialog"
                aria-modal="true"
                aria-labelledby="settings-dialog-title"
                phx-hook=".FocusTrap"
              >
                <div
                  class="bg-slate-800 border border-slate-700 rounded-xl shadow-2xl w-full max-w-2xl max-h-[85vh] flex flex-col animate-dialog-content"
                  phx-click-stop
                  id="settings-dialog"
                  tabindex="-1"
                >
                  <%!-- Dialog Header --%>
                  <div class="flex items-center justify-between px-6 py-4 border-b border-slate-700">
                    <h2 class="text-xl font-bold text-white" id="settings-dialog-title">Settings</h2>
                    <button
                      type="button"
                      phx-click="close_settings"
                      class="p-1 text-gray-400 hover:text-white transition-colors rounded-lg hover:bg-slate-700"
                      id="close-settings-btn"
                      aria-label="Close settings"
                    >
                      <.icon name="hero-x-mark" class="w-5 h-5" />
                    </button>
                  </div>

                  <%!-- Tab Navigation --%>
                  <div
                    class="flex border-b border-slate-700 px-6"
                    role="tablist"
                    aria-label="Settings tabs"
                  >
                    <button
                      type="button"
                      phx-click="switch_settings_tab"
                      phx-value-tab="general"
                      id="settings-tab-general"
                      role="tab"
                      aria-selected={to_string(@settings_tab == :general)}
                      aria-controls="settings-general-tab-panel"
                      class={[
                        "px-4 py-3 text-sm font-medium border-b-2 transition-colors -mb-px",
                        if(@settings_tab == :general,
                          do: "border-blue-500 text-blue-400",
                          else:
                            "border-transparent text-gray-400 hover:text-gray-200 hover:border-slate-500"
                        )
                      ]}
                    >
                      General
                    </button>
                    <button
                      type="button"
                      phx-click="switch_settings_tab"
                      phx-value-tab="generation"
                      id="settings-tab-generation"
                      role="tab"
                      aria-selected={to_string(@settings_tab == :generation)}
                      aria-controls="settings-generation-tab-panel"
                      class={[
                        "px-4 py-3 text-sm font-medium border-b-2 transition-colors -mb-px",
                        if(@settings_tab == :generation,
                          do: "border-blue-500 text-blue-400",
                          else:
                            "border-transparent text-gray-400 hover:text-gray-200 hover:border-slate-500"
                        )
                      ]}
                    >
                      Generation
                      <%= if generation_params_customized?(@generation_params) do %>
                        <span class="ml-1.5 px-1.5 py-0.5 text-xs bg-amber-600 text-white rounded-full">
                          Custom
                        </span>
                      <% end %>
                    </button>
                    <button
                      type="button"
                      phx-click="switch_settings_tab"
                      phx-value-tab="mcp"
                      id="settings-tab-mcp"
                      role="tab"
                      aria-selected={to_string(@settings_tab == :mcp)}
                      aria-controls="settings-mcp-tab-panel"
                      class={[
                        "px-4 py-3 text-sm font-medium border-b-2 transition-colors -mb-px",
                        if(@settings_tab == :mcp,
                          do: "border-blue-500 text-blue-400",
                          else:
                            "border-transparent text-gray-400 hover:text-gray-200 hover:border-slate-500"
                        )
                      ]}
                    >
                      MCP Servers
                      <%= if @mcp_enabled? and map_size(@mcp_tools) > 0 do %>
                        <span class="ml-1.5 px-1.5 py-0.5 text-xs bg-purple-600 text-white rounded-full">
                          {map_size(@mcp_tools)}
                        </span>
                      <% end %>
                    </button>
                  </div>

                  <%!-- Tab Content (scrollable) --%>
                  <div class="flex-1 overflow-y-auto px-6 py-5">
                    <%!-- General Tab --%>
                    <%= if @settings_tab == :general do %>
                      <div
                        class="space-y-6 animate-tab-panel"
                        id="settings-general-tab-panel"
                        role="tabpanel"
                        aria-labelledby="settings-tab-general"
                      >
                        <%!-- System Prompt Section --%>
                        <div>
                          <div class="flex items-center justify-between mb-2">
                            <label class="text-sm font-medium text-gray-200">System Prompt</label>
                            <%= if @system_prompt != "" do %>
                              <span class="px-2 py-0.5 text-xs bg-blue-600 text-white rounded-full">
                                Active
                              </span>
                            <% end %>
                          </div>
                          <.form
                            for={to_form(%{"system_prompt" => @system_prompt})}
                            id="settings-system-prompt-form"
                            phx-change="update_system_prompt"
                          >
                            <textarea
                              name="system_prompt"
                              placeholder="Enter a system prompt to set the model's behavior (e.g., 'You are a helpful coding assistant')..."
                              rows="4"
                              class="w-full bg-slate-900 text-white border border-slate-600 rounded-lg px-4 py-3 text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-y placeholder-slate-500"
                              phx-debounce="500"
                            >{@system_prompt}</textarea>
                          </.form>
                          <p class="mt-1.5 text-xs text-gray-500">
                            Sets the model's behavior and personality for all messages in this conversation.
                          </p>
                        </div>

                        <%!-- Storage Settings Section --%>
                        <div id="settings-storage-panel">
                          <label class="text-sm font-medium text-gray-200 mb-3 block">Storage</label>
                          <label class="flex items-start gap-3 cursor-pointer">
                            <input
                              type="checkbox"
                              phx-click="toggle_save_intermediate_events"
                              checked={@save_intermediate_events}
                              class="mt-0.5 rounded border-gray-600 text-blue-600 focus:ring-blue-500 focus:ring-offset-gray-900 bg-gray-700"
                            />
                            <div>
                              <div class="text-sm text-gray-300">Save tool activity in history</div>
                              <div class="text-xs text-gray-500 mt-0.5">
                                Stores tool calls and responses in localStorage. Disable to save storage space.
                              </div>
                            </div>
                          </label>
                        </div>
                      </div>
                    <% end %>

                    <%!-- Generation Tab --%>
                    <%= if @settings_tab == :generation do %>
                      <div
                        class="animate-tab-panel"
                        id="settings-generation-tab-panel"
                        role="tabpanel"
                        aria-labelledby="settings-tab-generation"
                      >
                        <.form
                          for={to_form(@generation_params)}
                          id="settings-generation-params-form"
                          phx-change="update_generation_params"
                        >
                          <div class="space-y-5">
                            <%!-- Temperature --%>
                            <div>
                              <label class="text-sm text-gray-200 flex justify-between mb-2">
                                <span class="font-medium">Temperature</span>
                                <span class="text-blue-400 font-mono text-xs bg-slate-900 px-2 py-0.5 rounded">
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
                              <div class="flex justify-between text-xs text-slate-500 mt-1">
                                <span>Precise</span>
                                <span>Creative</span>
                              </div>
                            </div>
                            <%!-- Max Tokens --%>
                            <div>
                              <label class="text-sm text-gray-200 flex justify-between mb-2">
                                <span class="font-medium">Max Tokens</span>
                                <span class="text-blue-400 font-mono text-xs bg-slate-900 px-2 py-0.5 rounded">
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
                              <div class="flex justify-between text-xs text-slate-500 mt-1">
                                <span>64</span>
                                <span>8192</span>
                              </div>
                            </div>
                            <%!-- Top P --%>
                            <div>
                              <label class="text-sm text-gray-200 flex justify-between mb-2">
                                <span class="font-medium">Top P</span>
                                <span class="text-blue-400 font-mono text-xs bg-slate-900 px-2 py-0.5 rounded">
                                  {@generation_params["top_p"]}
                                </span>
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
                              <div class="flex justify-between text-xs text-slate-500 mt-1">
                                <span>Focused</span>
                                <span>Diverse</span>
                              </div>
                            </div>
                            <%!-- Top K --%>
                            <div>
                              <label class="text-sm text-gray-200 flex justify-between mb-2">
                                <span class="font-medium">Top K</span>
                                <span class="text-blue-400 font-mono text-xs bg-slate-900 px-2 py-0.5 rounded">
                                  {@generation_params["top_k"]}
                                </span>
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
                              <div class="flex justify-between text-xs text-slate-500 mt-1">
                                <span>1</span>
                                <span>100</span>
                              </div>
                            </div>
                            <%!-- Context Window --%>
                            <div>
                              <label class="text-sm text-gray-200 flex justify-between mb-2">
                                <span class="font-medium">Context Window</span>
                                <span class="text-blue-400 font-mono text-xs bg-slate-900 px-2 py-0.5 rounded">
                                  {@generation_params["num_ctx"]}
                                </span>
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
                              <div class="flex justify-between text-xs text-slate-500 mt-1">
                                <span>512</span>
                                <span>131072</span>
                              </div>
                            </div>
                          </div>
                          <div class="mt-5 flex justify-end">
                            <button
                              type="button"
                              phx-click="reset_generation_params"
                              class="text-sm text-gray-400 hover:text-white transition-colors px-4 py-2 rounded-lg border border-slate-600 hover:border-slate-500 hover:bg-slate-700"
                              id="settings-reset-generation-params"
                            >
                              Reset to Defaults
                            </button>
                          </div>
                        </.form>
                      </div>
                    <% end %>

                    <%!-- MCP Servers Tab --%>
                    <%= if @settings_tab == :mcp do %>
                      <div
                        class="space-y-5 animate-tab-panel"
                        id="settings-mcp-tab-panel"
                        role="tabpanel"
                        aria-labelledby="settings-tab-mcp"
                      >
                        <%= if not @mcp_enabled? do %>
                          <div class="text-center py-8">
                            <.icon
                              name="hero-wrench-screwdriver"
                              class="w-12 h-12 text-gray-600 mx-auto mb-3"
                            />
                            <p class="text-gray-400 text-sm">MCP is not enabled.</p>
                            <p class="text-gray-500 text-xs mt-1">
                              Set
                              <code class="text-blue-400">
                                config :ollama_chat, :mcp_enabled, true
                              </code>
                              to enable.
                            </p>
                          </div>
                        <% else %>
                          <%!-- Error banner --%>
                          <%= if @mcp_form_error do %>
                            <div
                              class="px-4 py-3 bg-red-900/30 border border-red-700 rounded-lg text-sm text-red-300 animate-error-in"
                              id="mcp-form-error"
                            >
                              <div class="flex items-center gap-2">
                                <.icon name="hero-exclamation-triangle" class="w-4 h-4 flex-shrink-0" />
                                <span>{@mcp_form_error}</span>
                              </div>
                            </div>
                          <% end %>

                          <%= if @editing_mcp_server do %>
                            <%!-- Add/Edit Server Form --%>
                            <div id="mcp-server-form">
                              <div class="flex items-center justify-between mb-4">
                                <h3 class="text-sm font-semibold text-white">
                                  <%= if Enum.any?(@mcp_server_configs, fn s -> to_string(s.name) == @editing_mcp_server["name"] end) do %>
                                    Edit Server
                                  <% else %>
                                    Add Server
                                  <% end %>
                                </h3>
                                <button
                                  type="button"
                                  phx-click="cancel_edit_mcp_server"
                                  class="text-xs text-gray-400 hover:text-white transition-colors"
                                  id="cancel-edit-mcp-server"
                                >
                                  Cancel
                                </button>
                              </div>
                              <.form
                                for={to_form(@editing_mcp_server)}
                                id="mcp-server-edit-form"
                                phx-submit="save_mcp_server"
                                class="space-y-4"
                              >
                                <div class="grid grid-cols-2 gap-4">
                                  <div>
                                    <label class="block text-xs font-medium text-gray-300 mb-1">
                                      Server Name <span class="text-red-400">*</span>
                                    </label>
                                    <input
                                      type="text"
                                      name="name"
                                      value={@editing_mcp_server["name"]}
                                      placeholder="my_server"
                                      required
                                      class="w-full bg-slate-900 text-white border border-slate-600 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent placeholder-slate-500"
                                      id="mcp-server-name"
                                    />
                                    <p class="text-xs text-gray-500 mt-1">
                                      Unique identifier (no spaces)
                                    </p>
                                  </div>
                                  <div>
                                    <label class="block text-xs font-medium text-gray-300 mb-1">
                                      Display Name <span class="text-red-400">*</span>
                                    </label>
                                    <input
                                      type="text"
                                      name="display_name"
                                      value={@editing_mcp_server["display_name"]}
                                      placeholder="My MCP Server"
                                      required
                                      class="w-full bg-slate-900 text-white border border-slate-600 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent placeholder-slate-500"
                                      id="mcp-server-display-name"
                                    />
                                  </div>
                                </div>

                                <div>
                                  <label class="block text-xs font-medium text-gray-300 mb-1">
                                    Description
                                  </label>
                                  <input
                                    type="text"
                                    name="description"
                                    value={@editing_mcp_server["description"]}
                                    placeholder="Brief description of what this server provides"
                                    class="w-full bg-slate-900 text-white border border-slate-600 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent placeholder-slate-500"
                                    id="mcp-server-description"
                                  />
                                </div>

                                <div>
                                  <label class="block text-xs font-medium text-gray-300 mb-1">
                                    Command <span class="text-red-400">*</span>
                                  </label>
                                  <input
                                    type="text"
                                    name="command"
                                    value={@editing_mcp_server["command"]}
                                    placeholder="/path/to/mcp-server or npx"
                                    required
                                    class="w-full bg-slate-900 text-white border border-slate-600 rounded-lg px-3 py-2 text-sm font-mono focus:ring-2 focus:ring-blue-500 focus:border-transparent placeholder-slate-500"
                                    id="mcp-server-command"
                                  />
                                </div>

                                <div>
                                  <label class="block text-xs font-medium text-gray-300 mb-1">
                                    Arguments
                                  </label>
                                  <textarea
                                    name="args"
                                    rows="2"
                                    placeholder="One argument per line"
                                    class="w-full bg-slate-900 text-white border border-slate-600 rounded-lg px-3 py-2 text-sm font-mono focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-y placeholder-slate-500"
                                    id="mcp-server-args"
                                  >{@editing_mcp_server["args"]}</textarea>
                                  <p class="text-xs text-gray-500 mt-1">One argument per line</p>
                                </div>

                                <div class="grid grid-cols-2 gap-4">
                                  <label class="flex items-center gap-2 cursor-pointer">
                                    <input
                                      type="hidden"
                                      name="enabled"
                                      value="false"
                                    />
                                    <input
                                      type="checkbox"
                                      name="enabled"
                                      value="true"
                                      checked={@editing_mcp_server["enabled"]}
                                      class="rounded border-gray-600 text-blue-600 focus:ring-blue-500 focus:ring-offset-gray-900 bg-gray-700"
                                    />
                                    <span class="text-sm text-gray-300">Enabled</span>
                                  </label>
                                  <label class="flex items-center gap-2 cursor-pointer">
                                    <input
                                      type="hidden"
                                      name="requires_approval"
                                      value="false"
                                    />
                                    <input
                                      type="checkbox"
                                      name="requires_approval"
                                      value="true"
                                      checked={@editing_mcp_server["requires_approval"]}
                                      class="rounded border-gray-600 text-blue-600 focus:ring-blue-500 focus:ring-offset-gray-900 bg-gray-700"
                                    />
                                    <span class="text-sm text-gray-300">
                                      Require Approval for All Tools
                                    </span>
                                  </label>
                                </div>

                                <div>
                                  <label class="block text-xs font-medium text-gray-300 mb-1">
                                    Dangerous Tools
                                  </label>
                                  <input
                                    type="text"
                                    name="dangerous_tools"
                                    value={@editing_mcp_server["dangerous_tools"]}
                                    placeholder="write_file, delete_file, move_file"
                                    class="w-full bg-slate-900 text-white border border-slate-600 rounded-lg px-3 py-2 text-sm font-mono focus:ring-2 focus:ring-blue-500 focus:border-transparent placeholder-slate-500"
                                    id="mcp-server-dangerous-tools"
                                  />
                                  <p class="text-xs text-gray-500 mt-1">
                                    Comma-separated tool names that require user approval
                                  </p>
                                </div>

                                <div class="flex items-center justify-between pt-2 border-t border-slate-700">
                                  <%!-- Delete button (only for existing servers) --%>
                                  <%= if Enum.any?(@mcp_server_configs, fn s -> to_string(s.name) == @editing_mcp_server["name"] end) do %>
                                    <button
                                      type="button"
                                      phx-click="delete_mcp_server"
                                      phx-value-name={@editing_mcp_server["name"]}
                                      data-confirm="Delete this MCP server? This will stop the server and remove its configuration."
                                      class="px-3 py-2 text-sm text-red-400 hover:text-red-300 hover:bg-red-900/30 rounded-lg transition-colors"
                                      id="delete-mcp-server"
                                    >
                                      Delete Server
                                    </button>
                                  <% else %>
                                    <div></div>
                                  <% end %>
                                  <div class="flex gap-2">
                                    <button
                                      type="button"
                                      phx-click="cancel_edit_mcp_server"
                                      class="px-4 py-2 text-sm text-gray-400 hover:text-white rounded-lg border border-slate-600 hover:border-slate-500 transition-colors"
                                    >
                                      Cancel
                                    </button>
                                    <button
                                      type="submit"
                                      class="px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors"
                                      id="save-mcp-server"
                                    >
                                      Save Server
                                    </button>
                                  </div>
                                </div>
                              </.form>
                            </div>
                          <% else %>
                            <%!-- Server List --%>
                            <div>
                              <div class="flex items-center justify-between mb-3">
                                <label class="text-sm font-medium text-gray-200">
                                  Servers
                                  <span class="ml-2 px-2 py-0.5 text-xs bg-slate-700 text-gray-300 rounded-full">
                                    {length(@mcp_server_configs)}
                                  </span>
                                </label>
                                <button
                                  type="button"
                                  phx-click="add_mcp_server"
                                  class="px-3 py-1.5 text-xs font-medium bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors flex items-center gap-1.5"
                                  id="add-mcp-server-btn"
                                >
                                  <.icon name="hero-plus" class="w-3.5 h-3.5" /> Add Server
                                </button>
                              </div>

                              <%= if @mcp_server_configs == [] do %>
                                <div class="text-center py-8 bg-slate-900/50 rounded-lg border border-dashed border-slate-600">
                                  <.icon
                                    name="hero-server-stack"
                                    class="w-10 h-10 text-gray-600 mx-auto mb-2"
                                  />
                                  <p class="text-gray-400 text-sm">No MCP servers configured</p>
                                  <p class="text-gray-500 text-xs mt-1">
                                    Click "Add Server" to get started
                                  </p>
                                </div>
                              <% else %>
                                <div class="space-y-2">
                                  <%= for config <- @mcp_server_configs do %>
                                    <div
                                      class={[
                                        "px-4 py-3 rounded-lg border transition-colors",
                                        if(config.enabled,
                                          do: "bg-slate-900 border-slate-700",
                                          else: "bg-slate-900/50 border-slate-700/50 opacity-60"
                                        )
                                      ]}
                                      id={"mcp-server-#{config.name}"}
                                    >
                                      <div class="flex items-start justify-between gap-3">
                                        <div class="flex items-start gap-3 flex-1 min-w-0">
                                          <%!-- Status indicator --%>
                                          <div class="mt-1">
                                            <%= cond do %>
                                              <% Map.get(@mcp_server_status, config.name, %{})[:status] == :connected -> %>
                                                <span class="w-2.5 h-2.5 bg-green-500 rounded-full block">
                                                </span>
                                              <% Map.get(@mcp_server_status, config.name, %{})[:status] == :restarting -> %>
                                                <span class="w-2.5 h-2.5 bg-yellow-500 rounded-full block animate-pulse">
                                                </span>
                                              <% config.enabled -> %>
                                                <span class="w-2.5 h-2.5 bg-red-500 rounded-full block">
                                                </span>
                                              <% true -> %>
                                                <span class="w-2.5 h-2.5 bg-gray-600 rounded-full block">
                                                </span>
                                            <% end %>
                                          </div>
                                          <div class="flex-1 min-w-0">
                                            <div class="flex items-center gap-2">
                                              <span class="text-sm font-medium text-white truncate">
                                                {config.display_name}
                                              </span>
                                              <%= unless config.enabled do %>
                                                <span class="px-1.5 py-0.5 text-xs bg-slate-700 text-gray-400 rounded">
                                                  Disabled
                                                </span>
                                              <% end %>
                                            </div>
                                            <div class="text-xs text-gray-500 mt-0.5 truncate">
                                              {Map.get(config, :description, "")}
                                            </div>
                                            <div class="text-xs text-gray-600 mt-1 font-mono truncate">
                                              {config.command} {Enum.join(
                                                Map.get(config, :args, []),
                                                " "
                                              )}
                                            </div>
                                          </div>
                                        </div>
                                        <div class="flex items-center gap-1 flex-shrink-0">
                                          <%!-- Toggle enabled --%>
                                          <button
                                            type="button"
                                            phx-click="toggle_mcp_server_enabled"
                                            phx-value-name={to_string(config.name)}
                                            class={[
                                              "p-1.5 rounded-lg transition-colors",
                                              if(config.enabled,
                                                do: "text-green-400 hover:bg-green-900/30",
                                                else: "text-gray-500 hover:bg-slate-700"
                                              )
                                            ]}
                                            title={
                                              if config.enabled,
                                                do: "Disable server",
                                                else: "Enable server"
                                            }
                                            id={"toggle-mcp-#{config.name}"}
                                          >
                                            <.icon
                                              name={
                                                if config.enabled,
                                                  do: "hero-signal",
                                                  else: "hero-signal-slash"
                                              }
                                              class="w-4 h-4"
                                            />
                                          </button>
                                          <%!-- Edit button --%>
                                          <button
                                            type="button"
                                            phx-click="edit_mcp_server"
                                            phx-value-name={to_string(config.name)}
                                            class="p-1.5 text-gray-400 hover:text-white hover:bg-slate-700 rounded-lg transition-colors"
                                            title="Edit server"
                                            id={"edit-mcp-#{config.name}"}
                                          >
                                            <.icon name="hero-pencil-square" class="w-4 h-4" />
                                          </button>
                                        </div>
                                      </div>
                                    </div>
                                  <% end %>
                                </div>
                              <% end %>
                            </div>

                            <%!-- Available Tools --%>
                            <div>
                              <label class="text-sm font-medium text-gray-200 mb-3 block">
                                Available Tools
                                <span class="ml-2 px-2 py-0.5 text-xs bg-purple-600/50 text-purple-300 rounded-full">
                                  {map_size(@mcp_tools)}
                                </span>
                              </label>
                              <%= if map_size(@mcp_tools) == 0 do %>
                                <p class="text-sm text-gray-500 py-4 text-center">
                                  No tools discovered yet. Servers may still be connecting.
                                </p>
                              <% else %>
                                <div class="space-y-2 max-h-64 overflow-y-auto">
                                  <div
                                    :for={{name, info} <- @mcp_tools}
                                    class="px-4 py-3 bg-slate-900 rounded-lg border border-slate-700"
                                  >
                                    <div class="flex items-start justify-between gap-2">
                                      <div class="flex-1 min-w-0">
                                        <div class="font-medium text-blue-300 text-sm">{name}</div>
                                        <div class="text-gray-400 text-xs mt-0.5 leading-relaxed">
                                          {info.description}
                                        </div>
                                      </div>
                                      <%= if info.requires_approval do %>
                                        <span class="flex-shrink-0 px-1.5 py-0.5 text-xs bg-yellow-900/50 text-yellow-300 rounded whitespace-nowrap">
                                          Approval
                                        </span>
                                      <% end %>
                                    </div>
                                    <div class="mt-1.5 text-gray-500 text-xs">
                                      Server: <span class="text-gray-400">{info.server}</span>
                                    </div>
                                  </div>
                                </div>
                              <% end %>
                            </div>
                          <% end %>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Input area: Message composer with textarea, Attach and Send buttons --%>
            <div class="bg-slate-800/50 rounded-b-xl shadow-2xl backdrop-blur-sm border border-slate-700 border-t-0 p-4 flex-shrink-0 max-h-[300px] overflow-y-auto mt-auto">
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
                  <div class="flex-1 max-w-full relative group">
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

    <%!-- Toast Notification --%>
    <%= if @toast_message do %>
      <div
        class="fixed bottom-6 right-6 z-[60] max-w-sm animate-toast-in"
        id="toast-notification"
        phx-click="dismiss_toast"
      >
        <div class={[
          "flex items-center gap-3 px-4 py-3 rounded-lg shadow-xl border backdrop-blur-sm",
          case @toast_type do
            :success -> "bg-green-900/90 border-green-700 text-green-200"
            :warning -> "bg-amber-900/90 border-amber-700 text-amber-200"
            :error -> "bg-red-900/90 border-red-700 text-red-200"
            _ -> "bg-slate-800/90 border-slate-600 text-gray-200"
          end
        ]}>
          <%= case @toast_type do %>
            <% :success -> %>
              <.icon name="hero-check-circle" class="w-5 h-5 flex-shrink-0 text-green-400" />
            <% :warning -> %>
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 flex-shrink-0 text-amber-400" />
            <% :error -> %>
              <.icon name="hero-x-circle" class="w-5 h-5 flex-shrink-0 text-red-400" />
            <% _ -> %>
              <.icon name="hero-information-circle" class="w-5 h-5 flex-shrink-0 text-blue-400" />
          <% end %>
          <span class="text-sm font-medium">{@toast_message}</span>
          <button
            type="button"
            phx-click="dismiss_toast"
            class="ml-auto p-1 hover:bg-white/10 rounded transition-colors"
            aria-label="Dismiss notification"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
      </div>
    <% end %>

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

    <%!-- Model Selector hook for localStorage persistence --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ModelSelector">
      export default {
        storageKey: "ollama_chat_selected_model",

        mounted() {
          // Track a pending (user-initiated) model change that hasn't yet been
          // confirmed by the server. While pendingValue is set, updated() must
          // not re-assert the server's old selection and overwrite the user's choice.
          this.pendingValue = null;

          const saved = localStorage.getItem(this.storageKey);
          if (saved) {
            this.pushEvent("model_preference_loaded", { model: saved });
          }

          // When the user changes the dropdown:
          // 1. Record their intent so updated() won't revert while the round-trip is in flight.
          // 2. Push the model change event explicitly instead of relying on phx-change,
          //    so the event source is always clear and controllable from one place.
          this.el.addEventListener("change", () => {
            this.pendingValue = this.el.value;
            this.pushEvent("select_model", { model: this.el.value });
          });

          // Server pushes save_model_preference after processing select_model —
          // but also after conversation_loaded (for a different model).
          // Only clear pendingValue when the server confirms OUR specific pending
          // selection. If the confirmation is for a different model (e.g. the
          // conversation's model), preserve pendingValue so updated() won't revert.
          this.handleEvent("save_model_preference", ({ model }) => {
            try {
              localStorage.setItem(this.storageKey, model);
              if (this.pendingValue === null || model === this.pendingValue) {
                this.pendingValue = null;
              }
            } catch (e) {
              console.error("Failed to save model preference:", e);
            }
          });
        },

        updated() {
          // If the user just changed the model and we're waiting for server
          // confirmation, don't re-assert the server's stale selection.
          if (this.pendingValue !== null) {
            // Once the server's selected attribute catches up with our pending
            // value we can safely clear it (save_model_preference already did,
            // but this handles the edge case where the event races ahead of the
            // attribute diff).
            const confirmed = Array.from(this.el.options).find(
              opt => opt.hasAttribute("selected") && opt.value === this.pendingValue
            );
            if (confirmed) this.pendingValue = null;
            return;
          }

          // Some browsers reset select elements when nearby DOM changes occur
          // (e.g. form state restoration after morphdom patches the chat form).
          // Re-assert the server's intended selection from the `selected` attribute.
          const intended = Array.from(this.el.options).find(opt => opt.hasAttribute("selected"));
          if (intended && this.el.value !== intended.value) {
            this.el.value = intended.value;
          }
        }
      }
    </script>

    <%!-- Focus Trap hook for modal dialogs --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".FocusTrap">
      export default {
        mounted() {
          this.previouslyFocused = document.activeElement;

          this.focusableSelector =
            'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

          this.handleKeyDown = (e) => {
            if (e.key === "Tab") {
              const focusable = Array.from(this.el.querySelectorAll(this.focusableSelector));
              if (focusable.length === 0) return;

              const first = focusable[0];
              const last = focusable[focusable.length - 1];

              if (e.shiftKey) {
                if (document.activeElement === first) {
                  e.preventDefault();
                  last.focus();
                }
              } else {
                if (document.activeElement === last) {
                  e.preventDefault();
                  first.focus();
                }
              }
            }

            if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
              const tab = e.target.closest('[role="tab"]');
              if (!tab) return;

              const tablist = tab.closest('[role="tablist"]');
              if (!tablist) return;

              const tabs = Array.from(tablist.querySelectorAll('[role="tab"]'));
              const index = tabs.indexOf(tab);
              if (index === -1) return;

              let nextIndex;
              if (e.key === "ArrowRight") {
                nextIndex = (index + 1) % tabs.length;
              } else {
                nextIndex = (index - 1 + tabs.length) % tabs.length;
              }

              tabs[nextIndex].focus();
              tabs[nextIndex].click();
              e.preventDefault();
            }
          };

          this.el.addEventListener("keydown", this.handleKeyDown);

          requestAnimationFrame(() => {
            const first = this.el.querySelector(this.focusableSelector);
            if (first) first.focus();
          });
        },

        destroyed() {
          this.el.removeEventListener("keydown", this.handleKeyDown);
          if (this.previouslyFocused && typeof this.previouslyFocused.focus === "function") {
            this.previouslyFocused.focus();
          }
        }
      }
    </script>

    <%!-- Storage Settings Manager hook for preference persistence --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".StorageSettings">
      export default {
        mounted() {
          this.preferenceKey = "ollama_chat_save_intermediate_events";

          // Load preference from localStorage (default: false)
          this.loadPreference();

          // Listen for preference changes from LiveView
          this.handleEvent("save_preference", ({ save_intermediate_events }) => {
            try {
              localStorage.setItem(this.preferenceKey, JSON.stringify(save_intermediate_events));
              console.log("Saved intermediate events preference:", save_intermediate_events);
            } catch (e) {
              console.error("Failed to save preference:", e);
            }
          });

          // Listen for preference load requests
          this.handleEvent("load_preference", () => {
            this.loadPreference();
          });
        },

        loadPreference() {
          try {
            const saved = localStorage.getItem(this.preferenceKey);
            const preference = saved !== null ? JSON.parse(saved) : false; // Default to false
            this.pushEvent("preference_loaded", { save_intermediate_events: preference });
          } catch (e) {
            console.error("Failed to load preference:", e);
            this.pushEvent("preference_loaded", { save_intermediate_events: false });
          }
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
    # Trigger async memory extraction if the previous conversation was long enough
    old_history = socket.assigns.message_history
    conversation_id = socket.assigns.current_conversation_id

    if Memory.enabled?() and conversation_id != nil and
         MemoryExtractor.should_extract?(old_history) do
      # message_history is stored newest-first; reverse so the LLM sees chronological order
      messages = Enum.reverse(old_history)
      MemoryExtractor.extract_and_save_async(conversation_id, messages)
    end

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

  # Synthesises the combined Ollama connection + health-check state into a
  # single set of display values: {dot_class, label, text_class, bg_class}.
  defp ollama_status_display(assigns) do
    cond do
      assigns.ollama_status == :unknown ->
        {"bg-yellow-500 animate-pulse", "Starting…", "text-yellow-400",
         "bg-yellow-900/20 border-yellow-800/50"}

      assigns.ollama_status == :stopped ->
        {"bg-red-500", "Disconnected", "text-red-400", "bg-red-900/20 border-red-800/50"}

      assigns.health_check_enabled and not assigns.health_check_healthy ->
        {"bg-amber-500 animate-pulse", "Unhealthy", "text-amber-400",
         "bg-amber-900/20 border-amber-800/50"}

      true ->
        {"bg-green-500", "Connected", "text-gray-400", "bg-slate-800/60 border-slate-700/50"}
    end
  end

  defp ollama_status_tooltip(assigns) do
    base =
      case assigns.ollama_status do
        :running -> "Ollama is running and accepting requests"
        :stopped -> "Ollama is not running"
        :unknown -> "Checking Ollama status…"
      end

    health =
      if assigns.health_check_enabled do
        if assigns.health_check_healthy,
          do: " · Health check: passing",
          else: " · Health check: failing — Ollama is not responding to periodic probes"
      else
        ""
      end

    base <> health
  end

  defp mcp_status_tooltip(assigns) do
    tool_count = map_size(assigns.mcp_tools)
    server_configs = assigns.mcp_server_configs

    enabled_count =
      case server_configs do
        [] -> 0
        configs -> Enum.count(configs, & &1.enabled)
      end

    connected_count =
      assigns.mcp_server_status
      |> Enum.count(fn {_name, info} -> info[:status] == :connected end)

    cond do
      tool_count > 0 ->
        "MCP: #{tool_count} tools available from #{connected_count} connected server(s)"

      enabled_count > 0 ->
        "MCP: #{enabled_count} server(s) enabled, waiting for tools"

      true ->
        "MCP: enabled but no servers configured"
    end
  end

  defp settings_button_tooltip(assigns) do
    parts =
      [
        if(assigns.system_prompt != "", do: "Custom system prompt active"),
        if(generation_params_customized?(assigns.generation_params),
          do: "Generation parameters customized"
        ),
        if(assigns.mcp_enabled? and map_size(assigns.mcp_tools) > 0,
          do: "#{map_size(assigns.mcp_tools)} MCP tools available"
        )
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "Open settings"
      _ -> "Settings: " <> Enum.join(parts, ", ")
    end
  end

  defp fetch_mcp_tools do
    case MCPClient.list_tools() do
      {:ok, tools} -> tools
      {:error, _} -> %{}
    end
  end

  # MCP Tool Handling Functions

  defp handle_tool_call(socket, message_id, tool_name, args) do
    cond do
      BuiltinRegistry.builtin_tool?(tool_name) ->
        Logger.info("Built-in tool call: #{tool_name} with args: #{inspect(args)}")
        execute_builtin_tool(socket, message_id, tool_name, args)

      Map.has_key?(socket.assigns.mcp_tools, tool_name) ->
        tool_info = socket.assigns.mcp_tools[tool_name]

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
              # Execute immediately via MCP
              execute_mcp_tool(socket, message_id, tool_name, args)
            end

          {:error, validation_error} ->
            Logger.warning("Tool argument validation failed: #{validation_error}")

            socket
            |> assign(:error, "Invalid tool arguments: #{validation_error}")
            |> assign(:loading, false)
            |> assign(:streaming_pid, nil)
        end

      true ->
        Logger.warning("Unknown tool requested: #{tool_name}")

        socket
        |> assign(:error, "Unknown tool: #{tool_name}")
        |> assign(:loading, false)
        |> assign(:streaming_pid, nil)
    end
  end

  defp execute_builtin_tool(socket, message_id, tool_name, args) do
    updated_events =
      socket.assigns.streaming_events ++
        [
          %{
            type: :tool_call,
            tool_name: tool_name,
            args: args,
            timestamp: DateTime.utc_now()
          }
        ]

    socket = assign(socket, :streaming_events, updated_events)
    parent = self()

    spawn(fn ->
      case ToolRouter.route_tool_call(tool_name, args) do
        {:ok, result_text} ->
          send(parent, {:builtin_tool_result, message_id, tool_name, result_text})

        {:error, reason} ->
          send(parent, {:tool_error, message_id, tool_name, reason})
      end
    end)

    assign(socket, :loading, true)
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

    # Add system prompt with tools (built-in + MCP)
    system_prompt =
      if ToolPromptBuilder.any_tools_available?(socket.assigns.mcp_tools) do
        ToolPromptBuilder.build_tool_aware_system_prompt(
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

  # ── Memory Context (Phase 3) ─────────────────────────────────────────────────

  # Retrieves relevant memories for the given user message and returns them as a
  # list of %Memory.Entry{} structs. Returns [] when the memory system is
  # unavailable or on any error, so it never blocks the chat flow.
  defp retrieve_memory_context(user_message) do
    if Memory.available?() do
      limit = Application.get_env(:ollama_chat, :memory_max_results, 10)

      case Memory.retrieve_relevant(user_message, limit: limit) do
        {:ok, memories} ->
          if memories != [] do
            Logger.debug("Injecting #{length(memories)} memories into system prompt")
          end

          memories

        {:error, reason} ->
          Logger.warning(
            "Memory context retrieval failed: #{inspect(reason)}, proceeding without memories"
          )

          []
      end
    else
      []
    end
  end

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
      # During streaming: check live streaming events (need more than 1)
      message.id == streaming_message_id and message.streaming ->
        match?([_, _ | _], streaming_events)

      # After streaming: check persisted events on the message
      not message.streaming and is_list(Map.get(message, :intermediate_events)) ->
        message.intermediate_events != []

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
      Enum.map_join(attachment_contents, "\n", fn att ->
        """

        --- File: #{att.name} (#{format_file_size(att.size)}) ---
        #{att.content}
        --- End of #{att.name} ---
        """
      end)

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

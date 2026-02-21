defmodule OllamaChatWeb.ChatLive do
  use OllamaChatWeb, :live_view

  alias OllamaChat.{Markdown, OllamaClient}

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
      |> stream(:messages, [])

    if connected?(socket) do
      send(self(), :check_ollama_status)
      send(self(), :load_models)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"message" => message}, socket) do
    {:noreply, assign(socket, :form, to_form(%{"message" => message}))}
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

      spawn(fn ->
        result =
          OllamaClient.chat_stream(
            messages_for_api,
            fn chunk ->
              if chunk["message"] && chunk["message"]["content"] do
                send(parent, {:stream_chunk, assistant_message_id, chunk["message"]["content"]})
              end

              if chunk["done"] do
                send(parent, {:stream_done, assistant_message_id})
              end
            end,
            model: model
          )

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            send(parent, {:stream_error, assistant_message_id, reason})
        end
      end)

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

    # Stream all messages, rendering markdown for assistant messages
    socket =
      Enum.reduce(messages, socket, fn msg, acc ->
        html_content =
          if msg["role"] == "assistant",
            do: Markdown.render(msg["content"]),
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
        {:noreply, assign(socket, :available_models, [])}

      {:error, _reason} ->
        {:noreply, assign(socket, :available_models, [])}
    end
  end

  @impl true
  def handle_info({:stream_chunk, message_id, content}, socket) do
    current = socket.assigns.streaming_message
    new_content = current <> content

    # Update the streaming message
    updated_message = %{
      id: message_id,
      role: "assistant",
      content: new_content,
      html_content: nil,
      timestamp: DateTime.utc_now(),
      streaming: true
    }

    socket =
      socket
      |> stream_insert(:messages, updated_message)
      |> assign(:streaming_message, new_content)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_done, message_id}, socket) do
    # Finalize the message with rendered markdown
    raw_content = socket.assigns.streaming_message

    Logger.info(
      "Stream completed for message_id=#{message_id} (#{String.length(raw_content)} chars)"
    )

    final_message = %{
      id: message_id,
      role: "assistant",
      content: raw_content,
      html_content: Markdown.render(raw_content),
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

    # Auto-save conversation after each completed exchange
    conversation_data = %{
      messages: Enum.reverse(updated_history),
      model: socket.assigns.selected_model,
      conversation_id: socket.assigns.current_conversation_id
    }

    socket = push_event(socket, "save_conversation", conversation_data)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_error, message_id, reason}, socket) do
    Logger.error("Stream error for message_id=#{message_id}: #{inspect(reason)}")

    # Remove the failed assistant message
    socket =
      socket
      |> stream_delete(:messages, %{id: message_id})
      |> assign(:loading, false)
      |> assign(:streaming_message, "")

    # Check if it's a connection error and attempt recovery
    if is_connection_error?(reason) do
      Logger.info("Connection error detected, initiating recovery")
      send(self(), {:attempt_recovery, message_id})

      {:noreply,
       socket
       |> assign(:status_message, "Connection to Ollama lost. Attempting to reconnect...")
       |> assign(:error, nil)}
    else
      {:noreply,
       socket
       |> assign(:error, format_error(reason))
       |> assign(:status_message, nil)}
    end
  end

  @impl true
  def handle_info({:attempt_recovery, message_id}, socket) do
    parent = self()

    spawn(fn ->
      case OllamaClient.ensure_ollama_running() do
        :ok ->
          # Ollama is running or was successfully started
          Process.sleep(2000)

          if OllamaClient.ollama_running?() do
            send(parent, {:recovery_success, message_id})
          else
            send(parent, :recovery_failed)
          end

        {:error, reason} ->
          send(parent, {:recovery_failed, reason})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:recovery_success, _message_id}, socket) do
    Logger.info("Ollama recovery successful")

    # Clear status message after a delay
    Process.send_after(self(), :clear_status, 3000)

    # Reload models to update the list and confirm Ollama is ready
    send(self(), :load_models)

    {:noreply,
     socket
     |> assign(:ollama_status, :running)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info({:recovery_failed, reason}, socket) do
    Logger.error("Ollama recovery failed: #{reason}")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:status_message, nil)
     |> assign(:error, "Failed to start Ollama: #{reason}")}
  end

  @impl true
  def handle_info(:recovery_failed, socket) do
    Logger.error("Ollama recovery failed: not responding")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:status_message, nil)
     |> assign(:error, "Cannot connect to Ollama. Please ensure it is running.")}
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
            </div>
          </div>
        </div>

        <%!-- Status message display --%>
        <%= if @status_message do %>
          <div class="mb-4 p-4 bg-blue-900/50 border border-blue-500 rounded-lg text-blue-200">
            <div class="flex items-start gap-2">
              <.icon name="hero-information-circle" class="w-5 h-5 mt-0.5 flex-shrink-0" />
              <div>
                <p class="text-sm">{@status_message}</p>
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
          <div class="h-[600px] overflow-y-auto p-6 space-y-4 relative">
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
              <div :for={{id, message} <- @streams.messages} id={id} class="animate-fade-in">
                <%= if message.role == "user" do %>
                  <div class="flex justify-end">
                    <div class="bg-blue-600 text-white rounded-2xl rounded-tr-sm px-6 py-3 max-w-[80%] shadow-lg">
                      <p class="whitespace-pre-wrap break-words">{message.content}</p>
                    </div>
                  </div>
                <% else %>
                  <div class="flex justify-start">
                    <div class="bg-slate-700 text-white rounded-2xl rounded-tl-sm px-6 py-3 max-w-[80%] shadow-lg">
                      <%= if message.streaming do %>
                        <p class="whitespace-pre-wrap break-words">{message.content}</p>
                        <span class="inline-block w-2 h-4 bg-white ml-1 animate-pulse"></span>
                      <% else %>
                        <div class="prose-chat">{message.html_content}</div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

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
                    class="w-full bg-slate-900 text-white border-slate-600 focus:border-blue-500 focus:ring-blue-500 resize-y min-h-[100px]"
                  />
                </div>
                <button
                  type="submit"
                  disabled={@loading}
                  class={[
                    "px-6 py-3 rounded-lg font-medium transition-all duration-200",
                    "bg-blue-600 hover:bg-blue-700 text-white",
                    "disabled:opacity-50 disabled:cursor-not-allowed",
                    "flex items-center gap-2 flex-shrink-0"
                  ]}
                >
                  <%= if @loading do %>
                    <.icon name="hero-arrow-path" class="w-5 h-5 animate-spin" />
                    <span>Sending...</span>
                  <% else %>
                    <.icon name="hero-paper-airplane" class="w-5 h-5" />
                    <span>Send</span>
                  <% end %>
                </button>
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
            return [];
          }
        },

        getConversation(id) {
          const conversations = this.getConversations();
          return conversations.find(c => c.id === id);
        },

        saveConversation(data) {
          const { messages, model, conversation_id } = data;

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
            // Check if quota exceeded
            if (e.name === "QuotaExceededError") {
              this.pushEvent("storage_error", { message: "Storage quota exceeded" });
            }
          }
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
    |> assign(:message_history, [])
    |> assign(:current_conversation_id, nil)
    |> push_event("new_conversation", %{})
  end

  defp is_connection_error?(reason) do
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

  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) when is_map(reason) do
    case reason do
      %{reason: :econnrefused} -> "Cannot connect to Ollama server"
      %{reason: :timeout} -> "Connection to Ollama timed out"
      _ -> "An error occurred: #{inspect(reason)}"
    end
  end

  defp format_error(reason), do: "An error occurred: #{inspect(reason)}"
end

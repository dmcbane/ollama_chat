defmodule OllamaChatWeb.ChatLive do
  use OllamaChatWeb, :live_view

  alias OllamaChat.OllamaClient

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
      # Add user message
      user_message = %{
        id: generate_id(),
        role: "user",
        content: message,
        timestamp: DateTime.utc_now()
      }

      # Create assistant message placeholder
      assistant_message_id = generate_id()

      assistant_message = %{
        id: assistant_message_id,
        role: "assistant",
        content: "",
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
    {:noreply,
     socket
     |> stream(:messages, [], reset: true)
     |> assign(:messages_empty?, true)
     |> assign(:streaming_message, "")
     |> assign(:error, nil)
     |> assign(:status_message, nil)
     |> assign(:message_history, [])}
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
    # Finalize the message
    final_message = %{
      id: message_id,
      role: "assistant",
      content: socket.assigns.streaming_message,
      timestamp: DateTime.utc_now(),
      streaming: false
    }

    socket =
      socket
      |> stream_insert(:messages, final_message)
      |> assign(:loading, false)
      |> assign(:streaming_message, "")
      |> assign(:message_history, [final_message | socket.assigns.message_history])

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_error, message_id, reason}, socket) do
    # Remove the failed assistant message
    socket =
      socket
      |> stream_delete(:messages, %{id: message_id})
      |> assign(:loading, false)
      |> assign(:streaming_message, "")

    # Check if it's a connection error and attempt recovery
    if is_connection_error?(reason) do
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
    # Clear status message after a delay
    Process.send_after(self(), :clear_status, 3000)

    {:noreply,
     socket
     |> assign(:ollama_status, :running)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info({:recovery_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:status_message, nil)
     |> assign(:error, "Failed to start Ollama: #{reason}")}
  end

  @impl true
  def handle_info(:recovery_failed, socket) do
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

              <button
                type="button"
                phx-click="clear_chat"
                class="px-4 py-2 bg-slate-800 hover:bg-slate-700 text-white rounded-lg transition-colors border border-slate-700"
              >
                <.icon name="hero-trash" class="w-5 h-5" />
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
                      <p class="whitespace-pre-wrap break-words">{message.content}</p>
                      <%= if message.streaming do %>
                        <span class="inline-block w-2 h-4 bg-white ml-1 animate-pulse"></span>
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
    """
  end

  # Helper functions

  defp generate_id do
    "msg-#{System.unique_integer([:positive, :monotonic])}"
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

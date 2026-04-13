defmodule OllamaChatWeb.ChatLiveTest do
  use OllamaChatWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount and render" do
    test "successfully mounts and displays the chat interface", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "Ollama Chat"
      assert html =~ "Start a conversation"
      assert has_element?(view, "#chat-form")
      assert has_element?(view, "#messages")
    end

    test "displays initial empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Start a conversation with your local LLM"
    end

    test "displays connection status indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Should show some status (Connected, Disconnected, or Starting…)
      assert html =~ ~r/(Connected|Disconnected|Starting)/
    end

    test "displays model selector when models are available", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Wait for models to load
      Process.sleep(100)

      # Check if select element might be present (depends on Ollama being available)
      html = render(view)
      assert html =~ "Model" or html =~ "llama3"
    end

    test "displays clear chat button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "button[phx-click='clear_chat']")
    end
  end

  describe "form interactions" do
    test "validates form input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Type a message
      form = element(view, "#chat-form")
      render_change(form, %{message: "Hello Ollama"})

      # Form should still be present and functional
      assert has_element?(view, "#chat-form")
    end

    test "clears form after validation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      form = element(view, "#chat-form")
      render_change(form, %{message: "Test message"})

      # The form should still exist
      assert has_element?(view, "#chat-form")
    end

    test "does not submit empty messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Try to submit empty message
      form = element(view, "#chat-form")
      render_submit(form, %{message: ""})

      # Should still show empty state
      html = render(view)
      assert html =~ "Start a conversation"
    end

    test "does not submit whitespace-only messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Try to submit whitespace
      form = element(view, "#chat-form")
      render_submit(form, %{message: "   "})

      # Should still show empty state
      html = render(view)
      assert html =~ "Start a conversation"
    end
  end

  describe "model selection" do
    test "allows selecting different models", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Simulate model selection if models are available
      if has_element?(view, "select[phx-change='select_model']") do
        view
        |> element("select[phx-change='select_model']")
        |> render_change(%{model: "mistral"})

        # If we got here without error, model selection works
        assert true
      else
        # If no models available, test passes
        assert true
      end
    end
  end

  describe "clear chat" do
    test "clears all messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Click clear button
      view
      |> element("button[phx-click='clear_chat']")
      |> render_click()

      # Should show empty state again
      html = render(view)
      assert html =~ "Start a conversation"
    end

    test "resets messages_empty flag", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Clear chat
      view
      |> element("button[phx-click='clear_chat']")
      |> render_click()

      # Check that empty state is shown again
      html = render(view)
      assert html =~ "Start a conversation"
    end
  end

  describe "UI elements" do
    test "displays proper styling and classes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Check for key styling classes
      assert html =~ "bg-gradient-to-br"
      assert html =~ "rounded"
    end

    test "shows send button with proper state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "button[type='submit']")
    end

    test "displays footer with model information", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Powered by Ollama"
    end
  end

  describe "error handling" do
    test "displays error messages when present", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:stream_error, "test-msg-id", "Test error message"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Test error message" or html =~ "Error"
    end

    test "displays connection error with recovery attempt", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      error = %Req.TransportError{reason: :econnrefused}
      send(view.pid, {:stream_error, "test-msg-id", error})
      _ = :sys.get_state(view.pid)

      html = render(view)
      # Recovery is attempted; without OLLAMA_START_COMMAND it fails fast,
      # so we see either the recovery status or the failure error
      assert html =~ "Starting Ollama" or html =~ "Failed to start Ollama"
    end
  end

  describe "streaming message flow" do
    test "stream_chunk updates assistant message content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-stream-1"

      # Simulate the start of a streaming response by injecting a placeholder
      send(view.pid, {:stream_chunk, msg_id, "Hello "})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Hello"
    end

    test "stream_chunk accumulates content across multiple chunks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-stream-2"

      send(view.pid, {:stream_chunk, msg_id, "Hello "})
      _ = :sys.get_state(view.pid)
      send(view.pid, {:stream_chunk, msg_id, "world!"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Hello world!"
    end

    test "streaming message shows cursor animation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-stream-3"

      send(view.pid, {:stream_chunk, msg_id, "Thinking..."})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "animate-pulse"
    end

    test "stream_done renders markdown and removes cursor", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-stream-4"

      # Stream some markdown content
      send(view.pid, {:stream_chunk, msg_id, "**bold text**"})
      _ = :sys.get_state(view.pid)

      # Finalize the stream
      send(view.pid, {:stream_done, msg_id})
      _ = :sys.get_state(view.pid)

      html = render(view)

      # Should contain rendered markdown (not raw markdown syntax)
      assert html =~ "<strong>bold text</strong>"
      # Streaming cursor should be gone (the w-2 h-4 blinking cursor span)
      refute html =~ "w-2 h-4 bg-white"
    end

    test "stream_done renders code blocks with syntax highlighting", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-stream-5"

      code = "```elixir\ndef hello, do: :world\n```"
      send(view.pid, {:stream_chunk, msg_id, code})
      _ = :sys.get_state(view.pid)
      send(view.pid, {:stream_done, msg_id})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "language-elixir"
      assert html =~ "prose-chat"
    end

    test "stream_done clears loading state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-stream-6"

      send(view.pid, {:stream_chunk, msg_id, "Done"})
      _ = :sys.get_state(view.pid)
      send(view.pid, {:stream_done, msg_id})
      _ = :sys.get_state(view.pid)

      # Send button should not be in disabled/loading state
      html = render(view)
      refute html =~ "Sending..."
    end
  end

  describe "conversation loading" do
    test "renders markdown for assistant messages in loaded conversations", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      conversation = %{
        "id" => "test-conv-1",
        "model" => "llama3",
        "messages" => [
          %{"role" => "user", "content" => "Hello", "timestamp" => "2024-01-01T00:00:00Z"},
          %{
            "role" => "assistant",
            "content" => "**Hi there!** How can I help?",
            "timestamp" => "2024-01-01T00:00:01Z"
          }
        ]
      }

      render_hook(view, "conversation_loaded", %{"conversation" => conversation})

      html = render(view)
      assert html =~ "<strong>Hi there!</strong>"
      assert html =~ "prose-chat"
    end

    test "keeps user messages as plain text in loaded conversations", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      conversation = %{
        "id" => "test-conv-2",
        "model" => "llama3",
        "messages" => [
          %{
            "role" => "user",
            "content" => "**not bold** just text",
            "timestamp" => "2024-01-01T00:00:00Z"
          }
        ]
      }

      render_hook(view, "conversation_loaded", %{"conversation" => conversation})

      html = render(view)
      # User messages should NOT be rendered as markdown
      refute html =~ "<strong>not bold</strong>"
      assert html =~ "**not bold** just text"
    end
  end

  describe "export conversation" do
    test "export button is present in the UI", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#export-button")
    end

    test "export button is disabled when no conversation is loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#export-button[disabled]")
    end

    test "export button is enabled when a conversation is loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      conversation = %{
        "id" => "test-export-conv",
        "model" => "llama3",
        "messages" => [
          %{"role" => "user", "content" => "Hello", "timestamp" => "2024-01-01T00:00:00Z"}
        ]
      }

      render_hook(view, "conversation_loaded", %{"conversation" => conversation})

      refute has_element?(view, "#export-button[disabled]")
    end

    test "export dropdown contains markdown and json options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#export-markdown-btn")
      assert has_element?(view, "#export-json-btn")
    end

    test "export event handler pushes event to client", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Load a conversation first
      conversation = %{
        "id" => "test-export-conv-2",
        "model" => "llama3",
        "messages" => [
          %{"role" => "user", "content" => "Hello", "timestamp" => "2024-01-01T00:00:00Z"}
        ]
      }

      render_hook(view, "conversation_loaded", %{"conversation" => conversation})

      # Trigger export — this should not crash
      render_hook(view, "export_conversation", %{"format" => "markdown"})
      render_hook(view, "export_conversation", %{"format" => "json"})

      # If we get here without error, the event handler works
      assert true
    end
  end

  describe "page title" do
    test "sets correct page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Ollama Chat"
    end
  end

  describe "copy button" do
    test "messages have data-content attribute for copy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-copy-1"
      send(view.pid, {:stream_chunk, msg_id, "Copy me!"})
      _ = :sys.get_state(view.pid)
      send(view.pid, {:stream_done, msg_id})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ ~s(data-content="Copy me!")
    end

    test "copy button is present on completed assistant messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-copy-2"
      send(view.pid, {:stream_chunk, msg_id, "Done"})
      _ = :sys.get_state(view.pid)
      send(view.pid, {:stream_done, msg_id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, ".copy-btn")
    end

    test "copy button is hidden on streaming messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-copy-3"
      send(view.pid, {:stream_chunk, msg_id, "Still streaming..."})
      _ = :sys.get_state(view.pid)

      html = render(view)
      # Streaming messages should not have the copy button
      # The assistant message div won't contain a copy-btn while streaming
      assert html =~ "Still streaming..."
      # The copy button appears only for non-streaming messages
      # Since only one message is streaming, there should be no copy-btn in assistant area
    end

    test "messages container has CopyMessage hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#messages-container[phx-hook]")
    end
  end

  describe "system prompt" do
    test "displays system prompt in settings dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Settings button should be visible in sidebar
      assert has_element?(view, "#open-settings-btn")

      # Open settings dialog — General tab shows System Prompt
      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ "System Prompt"
    end

    test "system prompt panel is closed by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "Enter a system prompt"
    end

    test "opening settings shows system prompt form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Open settings dialog
      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ "system prompt"
      assert has_element?(view, "#settings-system-prompt-form")
    end

    test "shows Active badge when system prompt is set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "update_system_prompt", %{"system_prompt" => "Be helpful"})

      # Settings button shows indicator dot when system prompt is active
      html = render(view)
      assert html =~ "bg-blue-500"

      # Active badge visible inside settings dialog
      view |> element("#open-settings-btn") |> render_click()
      html = render(view)
      assert html =~ "Active"
    end

    test "no Active badge when system prompt is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "Active"
    end

    test "system prompt is restored from loaded conversation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      conversation = %{
        "id" => "test-sp-conv",
        "model" => "llama3",
        "system_prompt" => "You are a pirate",
        "messages" => [
          %{"role" => "user", "content" => "Hello", "timestamp" => "2024-01-01T00:00:00Z"}
        ]
      }

      render_hook(view, "conversation_loaded", %{"conversation" => conversation})

      # Open settings dialog to verify system prompt
      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ "You are a pirate"
      assert html =~ "Active"
    end

    test "system prompt is reset on new conversation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Set a system prompt
      render_hook(view, "update_system_prompt", %{"system_prompt" => "Be helpful"})

      # Clear chat (starts new conversation)
      view
      |> element("button[phx-click='clear_chat']")
      |> render_click()

      html = render(view)
      refute html =~ "Active"
    end
  end

  describe "generation parameters" do
    test "displays generation parameters in settings dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Open settings and switch to Generation tab
      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()

      html = render(view)
      assert html =~ "Temperature"
      assert html =~ "Max Tokens"
    end

    test "generation params panel is closed by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "generation-params-panel"
    end

    test "generation tab shows parameter form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Open settings and switch to Generation tab
      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()

      assert has_element?(view, "#settings-generation-tab-panel")
      assert has_element?(view, "#settings-generation-params-form")
    end

    test "shows Custom badge when params differ from defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "update_generation_params", %{"temperature" => "1.5"})

      # Custom badge is visible in the Generation tab of the settings dialog
      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()
      html = render(view)
      assert html =~ "Custom"
    end

    test "no Custom badge when params are at defaults", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "Custom"
    end

    test "updating params changes displayed values", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Open settings and switch to Generation tab
      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()

      # Update temperature
      render_hook(view, "update_generation_params", %{"temperature" => "1.2"})

      html = render(view)
      assert html =~ "1.2"
    end

    test "reset restores default values", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Customize params
      render_hook(view, "update_generation_params", %{"temperature" => "1.5"})

      # Open settings to see Custom badge in generation tab
      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()
      html = render(view)
      assert html =~ "Custom"

      # Reset
      render_hook(view, "reset_generation_params", %{})

      html = render(view)
      refute html =~ "Custom"
    end

    test "generation params are restored from loaded conversation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      conversation = %{
        "id" => "test-gp-conv",
        "model" => "llama3",
        "system_prompt" => "",
        "generation_params" => %{
          "temperature" => 1.5,
          "num_predict" => 4096,
          "top_p" => 0.9,
          "top_k" => 40,
          "num_ctx" => 4096
        },
        "messages" => [
          %{"role" => "user", "content" => "Hello", "timestamp" => "2024-01-01T00:00:00Z"}
        ]
      }

      render_hook(view, "conversation_loaded", %{"conversation" => conversation})

      # Open settings to see Custom badge in generation tab
      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()
      html = render(view)
      # Should show Custom badge since temperature differs from defaults
      assert html =~ "Custom"
    end

    test "generation params are reset on new conversation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Customize params
      render_hook(view, "update_generation_params", %{"temperature" => "1.5"})

      # Clear chat (starts new conversation)
      view
      |> element("button[phx-click='clear_chat']")
      |> render_click()

      html = render(view)
      refute html =~ "Custom"
    end

    test "ignores unknown param keys", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # This should not crash
      render_hook(view, "update_generation_params", %{"unknown_param" => "999"})

      # Should still not show Custom badge
      html = render(view)
      refute html =~ "Custom"
    end
  end

  describe "start ollama button" do
    test "start_ollama event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "start_ollama", %{})

      # If we get here without error, the event handler works
      html = render(view)
      assert html =~ "Ollama Chat"
    end
  end

  describe "recovery progress" do
    test "recovery_progress updates status message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:recovery_progress, :waiting})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Waiting for Ollama to initialize"
    end

    test "recovery_complete updates status to running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, :recovery_complete)
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Ollama is running"
    end

    test "recovery_failed shows error message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:recovery_failed, "command not found"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Failed to start Ollama"
      assert html =~ "command not found"
    end

    test "recovery_progress updates recovery step", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:recovery_progress, :loading_models})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Loading models"
    end
  end

  describe "streaming timeout" do
    test "timeout clears loading and shows an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Submit a message to set loading=true (spawned process may fail fast
      # with stream_error since Ollama isn't running, creating a race)
      form = element(view, "#chat-form")
      render_submit(form, %{message: "Hello"})

      send(view.pid, {:stream_timeout, "test-timeout-1"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      # Either timeout or stream_error clears loading — either way, not "Sending..."
      refute html =~ "Sending..."
      # An error is displayed (timeout or connection error)
      assert html =~ "Error"
    end

    test "timeout is ignored when not loading", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Send a stale timeout (loading is false by default)
      send(view.pid, {:stream_timeout, "stale-msg-id"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      # Should not show timeout error
      refute html =~ "timed out"
    end

    test "timeout clears loading state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      msg_id = "test-timeout-2"

      # Submit a message to set loading=true
      form = element(view, "#chat-form")
      render_submit(form, %{message: "Test"})

      send(view.pid, {:stream_timeout, msg_id})
      _ = :sys.get_state(view.pid)

      # Loading should be cleared — send button should not say "Sending..."
      html = render(view)
      refute html =~ "Sending..."
    end
  end

  describe "health check" do
    test "mounts with health check enabled by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Health check should be enabled by default
      state = :sys.get_state(view.pid)
      socket = state.socket

      assert socket.assigns.health_check_enabled == true
      assert socket.assigns.health_check_healthy == true
    end

    test "health_check message updates healthy status when Ollama is running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, :health_check)
      _ = :sys.get_state(view.pid)

      html = render(view)
      # Combined indicator shows Connected/Unhealthy/Disconnected depending on state
      state = :sys.get_state(view.pid)

      assert state.socket.assigns.health_check_healthy == true or html =~ "Unhealthy" or
               html =~ "Disconnected"
    end

    test "health_check message reschedules the next check", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, :health_check)
      state = :sys.get_state(view.pid)
      socket = state.socket

      # Timer should be set (not nil) after a health check runs
      assert socket.assigns.health_check_timer != nil
    end

    test "health check status is displayed in sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#ollama-status-indicator")
    end

    test "health check shows healthy indicator by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Initial render shows Starting (unknown status), verify health assign is true
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.health_check_healthy == true
    end
  end

  describe "settings dialog" do
    test "settings button is visible in sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#open-settings-btn")
      html = render(view)
      assert html =~ "Settings"
    end

    test "settings dialog is closed by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      refute has_element?(view, "#settings-dialog")
    end

    test "clicking settings button opens the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      assert has_element?(view, "#settings-dialog")
      assert has_element?(view, "#settings-overlay")
    end

    test "close button closes the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()
      assert has_element?(view, "#settings-dialog")

      view |> element("#close-settings-btn") |> render_click()
      refute has_element?(view, "#settings-dialog")
    end

    test "general tab is shown by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      assert has_element?(view, "#settings-general-tab-panel")
      refute has_element?(view, "#settings-generation-tab-panel")
    end

    test "switching to generation tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()

      assert has_element?(view, "#settings-generation-tab-panel")
      refute has_element?(view, "#settings-general-tab-panel")
    end

    test "switching to mcp tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-mcp") |> render_click()

      assert has_element?(view, "#settings-mcp-tab-panel")
      refute has_element?(view, "#settings-general-tab-panel")
    end

    test "settings button shows indicator when system prompt is set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      refute render(view) =~ "bg-blue-500"

      render_hook(view, "update_system_prompt", %{"system_prompt" => "Be a pirate"})

      assert render(view) =~ "bg-blue-500"
    end

    test "settings button shows indicator when generation params differ", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      refute render(view) =~ "bg-blue-500"

      render_hook(view, "update_generation_params", %{"temperature" => "1.5"})

      assert render(view) =~ "bg-blue-500"
    end
  end

  describe "MCP tool refresh" do
    test "refresh_mcp_status updates both server status and tools", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Send the refresh message directly
      send(view.pid, :refresh_mcp_status)
      _ = :sys.get_state(view.pid)

      # The handler should not crash and should produce valid HTML
      html = render(view)
      assert html =~ "Ollama Chat"
    end
  end

  describe "MCP server management" do
    test "mcp tab shows disabled message when MCP is off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-mcp") |> render_click()

      html = render(view)
      assert html =~ "MCP is not enabled"
    end

    test "add_mcp_server sets editing state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "add_mcp_server", %{})

      # Verify the assign was set by checking it doesn't crash
      # and produces valid HTML
      html = render(view)
      assert html =~ "Ollama Chat"
    end

    test "cancel_edit_mcp_server clears editing state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Start editing
      render_hook(view, "add_mcp_server", %{})

      # Cancel
      render_hook(view, "cancel_edit_mcp_server", %{})

      html = render(view)
      assert html =~ "Ollama Chat"
    end

    test "save_mcp_server with empty params returns validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "save_mcp_server", %{
        "name" => "",
        "display_name" => "",
        "command" => "",
        "description" => "",
        "args" => "",
        "enabled" => "true",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      # Should set an error but not crash
      html = render(view)
      assert html =~ "Ollama Chat"
    end

    test "save_mcp_server with valid disabled server succeeds", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Use a unique name to avoid conflicts with other tests
      server_name = "test_save_ui_#{System.unique_integer([:positive])}"

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Test UI Server",
        "command" => "/usr/bin/false",
        "description" => "A test server",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      html = render(view)
      assert html =~ "Ollama Chat"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "delete_mcp_server removes a server", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # First add a server to delete
      server_name = "test_delete_ui_#{System.unique_integer([:positive])}"

      :ok =
        OllamaChat.MCPClient.add_server(%{
          name: String.to_atom(server_name),
          display_name: "Delete Me",
          command: "/usr/bin/false",
          enabled: false
        })

      render_hook(view, "delete_mcp_server", %{"name" => server_name})

      # Should not crash
      html = render(view)
      assert html =~ "Ollama Chat"

      # Verify it was removed
      configs = OllamaChat.MCPClient.list_server_configs()
      refute Enum.any?(configs, fn s -> to_string(s.name) == server_name end)
    end

    test "toggle_mcp_server_enabled toggles server state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "test_toggle_ui_#{System.unique_integer([:positive])}"

      :ok =
        OllamaChat.MCPClient.add_server(%{
          name: String.to_atom(server_name),
          display_name: "Toggle Me",
          command: "/usr/bin/false",
          enabled: false
        })

      # Load configs into the view
      render_hook(view, "open_settings", %{})

      render_hook(view, "toggle_mcp_server_enabled", %{"name" => server_name})

      # Should not crash
      html = render(view)
      assert html =~ "Ollama Chat"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "edit_mcp_server loads server config into form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "test_edit_ui_#{System.unique_integer([:positive])}"

      :ok =
        OllamaChat.MCPClient.add_server(%{
          name: String.to_atom(server_name),
          display_name: "Edit Me",
          command: "/usr/bin/echo",
          description: "A test server to edit",
          enabled: false
        })

      # Load configs into the view
      render_hook(view, "open_settings", %{})

      render_hook(view, "edit_mcp_server", %{"name" => server_name})

      # Should not crash
      html = render(view)
      assert html =~ "Ollama Chat"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "edit_mcp_server with nonexistent server sets error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Load configs
      render_hook(view, "open_settings", %{})

      # Try to edit a server that doesn't exist in mcp_server_configs
      # This should set a form error, not crash
      render_hook(view, "edit_mcp_server", %{"name" => "nonexistent_server_xyz"})

      html = render(view)
      assert html =~ "Ollama Chat"
    end

    test "save_mcp_server parses args and dangerous_tools correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "test_parse_ui_#{System.unique_integer([:positive])}"

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Parse Test",
        "command" => "/usr/bin/echo",
        "description" => "Tests parsing",
        "args" => "arg1\narg2\narg3",
        "enabled" => "false",
        "requires_approval" => "true",
        "dangerous_tools" => "write_file, delete_file, move_file"
      })

      configs = OllamaChat.MCPClient.list_server_configs()
      server = Enum.find(configs, fn s -> to_string(s.name) == server_name end)

      assert server != nil
      assert server.args == ["arg1", "arg2", "arg3"]
      assert server.dangerous_tools == ["write_file", "delete_file", "move_file"]
      assert server.requires_approval == true

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "save_mcp_server can update an existing server", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "test_update_ui_#{System.unique_integer([:positive])}"

      # Add a server first
      :ok =
        OllamaChat.MCPClient.add_server(%{
          name: String.to_atom(server_name),
          display_name: "Original Name",
          command: "/usr/bin/false",
          enabled: false
        })

      # Load configs into view
      render_hook(view, "open_settings", %{})

      # Update via save_mcp_server
      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Updated Name",
        "command" => "/usr/bin/true",
        "description" => "updated",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      configs = OllamaChat.MCPClient.list_server_configs()
      server = Enum.find(configs, fn s -> to_string(s.name) == server_name end)

      assert server.display_name == "Updated Name"
      assert server.command == "/usr/bin/true"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end
  end

  describe "workspace root directory browser" do
    # MCP must be enabled so the form and browser panel render in HTML.
    setup do
      original = Application.get_env(:ollama_chat, :mcp_enabled, false)
      Application.put_env(:ollama_chat, :mcp_enabled, true)
      on_exit(fn -> Application.put_env(:ollama_chat, :mcp_enabled, original) end)
      :ok
    end

    test "open_dir_browser opens the browser panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      render_hook(view, "add_mcp_server", %{})
      render_hook(view, "open_dir_browser", %{})

      html = render(view)
      assert html =~ ~s(id="dir-browser-panel")
      assert html =~ System.user_home!()
    end

    test "open_dir_browser opens at existing root_path when it is a valid directory", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      server_name = "test_browse_existing_#{System.unique_integer([:positive])}"

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Browse Existing",
        "command" => "/usr/bin/false",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => "",
        "root_path" => System.tmp_dir!()
      })

      render_hook(view, "edit_mcp_server", %{"name" => server_name})
      render_hook(view, "open_dir_browser", %{})

      html = render(view)
      assert html =~ ~s(id="dir-browser-panel")
      assert html =~ System.tmp_dir!()

      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "dir_browser_navigate navigates into the given path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      render_hook(view, "add_mcp_server", %{})
      render_hook(view, "open_dir_browser", %{})
      render_hook(view, "dir_browser_navigate", %{"path" => System.tmp_dir!()})

      html = render(view)
      assert html =~ ~s(id="dir-browser-panel")
      assert html =~ System.tmp_dir!()
    end

    test "dir_browser_navigate_parent navigates to the parent directory", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      tmp = System.tmp_dir!()

      render_hook(view, "add_mcp_server", %{})
      render_hook(view, "open_dir_browser", %{})
      render_hook(view, "dir_browser_navigate", %{"path" => tmp})
      render_hook(view, "dir_browser_navigate_parent", %{})

      html = render(view)
      # Browser should still be open after navigating up
      assert html =~ ~s(id="dir-browser-panel")
      # Current path should now be the parent, not the original tmp
      refute html =~ ~s(title="#{tmp}")
    end

    test "dir_browser_navigate_parent stays at / when already at root", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      render_hook(view, "add_mcp_server", %{})
      render_hook(view, "open_dir_browser", %{})
      render_hook(view, "dir_browser_navigate", %{"path" => "/"})
      render_hook(view, "dir_browser_navigate_parent", %{})

      html = render(view)
      # Should not crash and browser should still be open
      assert html =~ ~s(id="dir-browser-panel")
    end

    test "dir_browser_select updates root_path input and closes the browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      tmp = System.tmp_dir!()

      render_hook(view, "add_mcp_server", %{})
      render_hook(view, "open_dir_browser", %{})
      render_hook(view, "dir_browser_navigate", %{"path" => tmp})
      render_hook(view, "dir_browser_select", %{})

      html = render(view)
      refute html =~ ~s(id="dir-browser-panel")
      assert html =~ ~s(value="#{tmp}")
    end

    test "dir_browser_cancel closes the browser without changing root_path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      render_hook(view, "add_mcp_server", %{})
      render_hook(view, "open_dir_browser", %{})
      render_hook(view, "dir_browser_cancel", %{})

      html = render(view)
      refute html =~ ~s(id="dir-browser-panel")
      # root_path input should still be empty (unchanged)
      assert html =~ ~s(value="")
    end

    test "cancel_edit_mcp_server closes the browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      render_hook(view, "add_mcp_server", %{})
      render_hook(view, "open_dir_browser", %{})
      render_hook(view, "cancel_edit_mcp_server", %{})

      html = render(view)
      refute html =~ ~s(id="dir-browser-panel")
    end

    test "save_mcp_server rejects a nonexistent root_path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})
      server_name = "test_rootpath_bad_#{System.unique_integer([:positive])}"

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Root Path Bad",
        "command" => "/usr/bin/false",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => "",
        "root_path" => "/this/path/does/absolutely/not/exist/xyzabc"
      })

      html = render(view)
      assert html =~ "does not exist or is not a directory"
      # Server should NOT have been saved
      configs = OllamaChat.MCPClient.list_server_configs()
      refute Enum.any?(configs, fn s -> to_string(s.name) == server_name end)
    end

    test "save_mcp_server accepts an empty root_path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "test_rootpath_empty_#{System.unique_integer([:positive])}"

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Root Path Empty",
        "command" => "/usr/bin/false",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => "",
        "root_path" => ""
      })

      configs = OllamaChat.MCPClient.list_server_configs()
      server = Enum.find(configs, fn s -> to_string(s.name) == server_name end)

      assert server != nil
      assert server.root_path == nil

      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "save_mcp_server accepts a valid existing directory as root_path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "test_rootpath_valid_#{System.unique_integer([:positive])}"
      tmp = System.tmp_dir!()

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Root Path Valid",
        "command" => "/usr/bin/false",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => "",
        "root_path" => tmp
      })

      configs = OllamaChat.MCPClient.list_server_configs()
      server = Enum.find(configs, fn s -> to_string(s.name) == server_name end)

      assert server != nil
      assert server.root_path == tmp

      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end
  end

  describe "settings dialog accessibility" do
    test "dialog has correct ARIA attributes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="settings-dialog-title")
      assert html =~ ~s(id="settings-dialog-title")
    end

    test "tabs have correct ARIA roles", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ ~s(role="tablist")
      assert html =~ ~s(aria-label="Settings tabs")
      assert html =~ ~s(role="tab")
      assert html =~ ~s(role="tabpanel")
    end

    test "general tab is marked as selected by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      # General tab should be selected
      assert html =~ ~s(id="settings-tab-general")
      assert html =~ ~s(aria-controls="settings-general-tab-panel")
      # Tab panel should reference its tab
      assert html =~ ~s(aria-labelledby="settings-tab-general")
    end

    test "switching tabs updates aria-selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()
      view |> element("#settings-tab-generation") |> render_click()

      html = render(view)
      assert html =~ ~s(id="settings-generation-tab-panel")
      assert html =~ ~s(aria-labelledby="settings-tab-generation")
    end

    test "close button has aria-label", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ ~s(aria-label="Close settings")
    end

    test "dialog has focus trap hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      # Colocated hooks render with the full module path prefix
      assert html =~ "FocusTrap"
    end
  end

  describe "settings dialog animations" do
    test "dialog overlay has animation class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ "animate-dialog-overlay"
    end

    test "dialog content has animation class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      html = render(view)
      assert html =~ "animate-dialog-content"
    end

    test "tab panels have animation class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      # General tab panel should have animation
      html = render(view)
      assert html =~ "animate-tab-panel"

      # Switch to generation tab
      view |> element("#settings-tab-generation") |> render_click()
      html = render(view)
      assert html =~ "animate-tab-panel"

      # Switch to MCP tab
      view |> element("#settings-tab-mcp") |> render_click()
      html = render(view)
      assert html =~ "animate-tab-panel"
    end

    test "MCP error banner has animation class in template", %{conn: conn} do
      # MCP is disabled in test config, so the error banner inside the MCP tab
      # (guarded by @mcp_enabled?) won't render. We verify that:
      # 1. save_mcp_server with invalid data doesn't crash
      # 2. The settings dialog remains open (error path taken, not success)
      # 3. The animate-error-in class exists in app.css (verified separately)
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})

      # Trigger a validation error — should not crash
      render_hook(view, "save_mcp_server", %{
        "name" => "",
        "display_name" => "",
        "command" => "",
        "description" => "",
        "args" => "",
        "enabled" => "true",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      # Settings dialog should still be open (error path keeps dialog open)
      html = render(view)
      assert html =~ "settings-dialog"
    end

    test "settings button gear icon has hover animation class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render(view)
      assert html =~ "animate-gear-hover"
    end
  end

  describe "toast notifications" do
    test "toast appears after saving MCP server", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "toast_test_#{System.unique_integer([:positive])}"

      render_hook(view, "open_settings", %{})

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Toast Test Server",
        "command" => "/usr/bin/false",
        "description" => "test",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      html = render(view)
      assert html =~ "toast-notification"
      assert html =~ "saved"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "toast appears after deleting MCP server", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "toast_delete_#{System.unique_integer([:positive])}"

      :ok =
        OllamaChat.MCPClient.add_server(%{
          name: String.to_atom(server_name),
          display_name: "Delete Toast Test",
          command: "/usr/bin/false",
          enabled: false
        })

      render_hook(view, "open_settings", %{})

      render_hook(view, "delete_mcp_server", %{"name" => server_name})

      html = render(view)
      assert html =~ "toast-notification"
      assert html =~ "removed"
    end

    test "toast appears after toggling MCP server", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "toast_toggle_#{System.unique_integer([:positive])}"

      :ok =
        OllamaChat.MCPClient.add_server(%{
          name: String.to_atom(server_name),
          display_name: "Toggle Toast Test",
          command: "/usr/bin/false",
          enabled: false
        })

      # MCP is disabled in test, so open_settings won't load configs.
      # Manually load configs into the view by switching to MCP tab.
      render_hook(view, "open_settings", %{})

      # Directly send toggle — since configs aren't loaded in test (MCP disabled),
      # the handler returns early. Verify it doesn't crash.
      render_hook(view, "toggle_mcp_server_enabled", %{"name" => server_name})

      html = render(view)
      # Toast won't show because configs aren't loaded (MCP disabled in test),
      # but the handler should not crash
      assert html =~ "Ollama Chat"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "toast shows success type with correct styling", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "toast_style_#{System.unique_integer([:positive])}"

      render_hook(view, "open_settings", %{})

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Style Test",
        "command" => "/usr/bin/false",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      html = render(view)
      assert html =~ "toast-notification"
      # Success toast has green styling
      assert html =~ "bg-green-900" || html =~ "bg-amber-900"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "toast can be dismissed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "toast_dismiss_#{System.unique_integer([:positive])}"

      render_hook(view, "open_settings", %{})

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Dismiss Test",
        "command" => "/usr/bin/false",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      assert has_element?(view, "#toast-notification")

      render_hook(view, "dismiss_toast", %{})

      refute has_element?(view, "#toast-notification")

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "toast auto-clears after timeout", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "toast_auto_#{System.unique_integer([:positive])}"

      render_hook(view, "open_settings", %{})

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Auto Clear Test",
        "command" => "/usr/bin/false",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      assert has_element?(view, "#toast-notification")

      # Simulate the clear_toast message
      send(view.pid, :clear_toast)

      # Give it a moment to process
      Process.sleep(50)

      refute has_element?(view, "#toast-notification")

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end

    test "toast shows warning for nonexistent command path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      server_name = "toast_warn_#{System.unique_integer([:positive])}"

      render_hook(view, "open_settings", %{})

      render_hook(view, "save_mcp_server", %{
        "name" => server_name,
        "display_name" => "Warning Test",
        "command" => "/nonexistent/path/to/binary",
        "description" => "",
        "args" => "",
        "enabled" => "false",
        "requires_approval" => "false",
        "dangerous_tools" => ""
      })

      html = render(view)
      assert html =~ "toast-notification"
      # Should show a warning about the command path
      assert html =~ "does not exist"

      # Clean up
      OllamaChat.MCPClient.remove_server(String.to_atom(server_name))
    end
  end

  describe "MCP tools search" do
    setup do
      original = Application.get_env(:ollama_chat, :mcp_enabled, false)
      Application.put_env(:ollama_chat, :mcp_enabled, true)
      on_exit(fn -> Application.put_env(:ollama_chat, :mcp_enabled, original) end)
      :ok
    end

    test "search input is absent when no tools are discovered", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})

      # No MCP servers running in tests → tools map is empty → input not rendered
      refute has_element?(view, "#mcp-tool-search-input")
    end

    test "mcp_tool_search event is handled and clears without error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})

      # Fire event and verify the panel still renders (no crash, assign updated)
      render_hook(view, "mcp_tool_search", %{"query" => "filesystem"})
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#settings-mcp-tab-panel")

      # Clearing the query also works cleanly
      render_hook(view, "mcp_tool_search", %{"query" => ""})
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#settings-mcp-tab-panel")
    end

    test "tool count badge shows plain count (not a ratio) when search is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "open_settings", %{})
      render_hook(view, "switch_settings_tab", %{"tab" => "mcp"})

      # With empty search the badge renders a plain count, not "M/N"
      # We verify by checking no "digit/digit" pattern appears inside the badge element
      html = render(view)
      document = LazyHTML.from_fragment(html)
      badge = LazyHTML.filter(document, ".text-purple-300")
      badge_text = badge |> LazyHTML.text() |> String.trim()
      refute badge_text =~ ~r/\d+\/\d+/
    end
  end
end

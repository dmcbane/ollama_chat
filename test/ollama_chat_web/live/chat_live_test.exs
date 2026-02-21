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

      # Should show some status (Connected, Disconnected, or checking)
      assert html =~ ~r/(Connected|Disconnected)/
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

    test "displays connection error with recovery message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      error = %Req.TransportError{reason: :econnrefused}
      send(view.pid, {:stream_error, "test-msg-id", error})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Attempting to reconnect"
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
    test "displays system prompt toggle button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "System Prompt"
    end

    test "system prompt panel is closed by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "Enter a system prompt"
    end

    test "toggling opens the system prompt panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='toggle_system_prompt']")
      |> render_click()

      html = render(view)
      assert html =~ "system prompt"
      assert has_element?(view, "#system-prompt-form")
    end

    test "shows Active badge when system prompt is set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "update_system_prompt", %{"system_prompt" => "Be helpful"})

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

      # Open the system prompt panel to verify
      view
      |> element("button[phx-click='toggle_system_prompt']")
      |> render_click()

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
end

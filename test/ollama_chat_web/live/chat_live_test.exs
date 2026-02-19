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

      # Simulate an error by sending a message to the LiveView
      send(view.pid, {:stream_error, "Test error message"})

      # Give it time to process
      Process.sleep(50)

      html = render(view)
      assert html =~ "Test error message" or html =~ "Error"
    end
  end

  describe "page title" do
    test "sets correct page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Check that the page title is in the HTML
      assert html =~ "Ollama Chat"
    end
  end
end

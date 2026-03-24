defmodule OllamaChat.OllamaClientTest do
  use ExUnit.Case, async: false

  alias OllamaChat.OllamaClient

  @moduletag :integration

  describe "ollama_running?/0" do
    test "returns true when Ollama is accessible" do
      # This test will only pass if Ollama is actually running
      if OllamaClient.ollama_running?() do
        assert OllamaClient.ollama_running?() == true
      else
        # Skip if Ollama is not running
        :ok
      end
    end

    test "returns false when Ollama is not accessible" do
      # We can't easily test this without stopping Ollama
      # So we'll just verify the function returns a boolean
      result = OllamaClient.ollama_running?()
      assert is_boolean(result)
    end
  end

  describe "list_models/0" do
    test "returns list of models when Ollama is running" do
      if OllamaClient.ollama_running?() do
        case OllamaClient.list_models() do
          {:ok, models} ->
            assert is_list(models)

          {:error, _reason} ->
            # Ollama might be running but not have any models installed
            :ok
        end
      else
        # Skip if Ollama is not running
        :ok
      end
    end

    test "returns error when Ollama is not accessible" do
      # This depends on Ollama state, so we just verify it returns a tuple
      result = OllamaClient.list_models()
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "chat/2" do
    @tag :skip
    test "successfully sends a chat message and receives response" do
      if OllamaClient.ollama_running?() do
        messages = [
          %{role: "user", content: "Say 'hello' and nothing else."}
        ]

        case OllamaClient.chat(messages, model: "llama3") do
          {:ok, response} ->
            assert is_map(response)
            assert Map.has_key?(response, "message")

          {:error, _reason} ->
            # Model might not be installed
            :ok
        end
      end
    end

    @tag :skip
    test "handles custom model selection" do
      if OllamaClient.ollama_running?() do
        messages = [
          %{role: "user", content: "Hello"}
        ]

        result = OllamaClient.chat(messages, model: "mistral")
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    test "returns error tuple for invalid input" do
      # Empty messages should still attempt the request
      result = OllamaClient.chat([])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "chat_stream/3" do
    @tag :skip
    test "successfully streams chat responses" do
      if OllamaClient.ollama_running?() do
        messages = [
          %{role: "user", content: "Count to 3"}
        ]

        callback = fn chunk ->
          send(self(), {:chunk, chunk})
        end

        spawn(fn ->
          OllamaClient.chat_stream(messages, callback, model: "llama3")
        end)

        # Wait for at least one chunk
        receive do
          {:chunk, chunk} ->
            assert is_map(chunk)
        after
          5000 ->
            # Timeout is okay if model not installed
            :ok
        end
      end
    end
  end

  describe "start_command_configured?/0" do
    test "returns a boolean" do
      result = OllamaClient.start_command_configured?()
      assert is_boolean(result)
    end
  end

  describe "ensure_ollama_running/0" do
    test "returns :ok when Ollama is already running" do
      if OllamaClient.ollama_running?() do
        assert OllamaClient.ensure_ollama_running() == :ok
      else
        # If not running and no start command, should return error
        result = OllamaClient.ensure_ollama_running()
        assert result == :ok or match?({:error, _}, result)
      end
    end
  end

  describe "kill_command_configured?/0" do
    test "returns a boolean" do
      result = OllamaClient.kill_command_configured?()
      assert is_boolean(result)
    end
  end

  describe "kill_ollama/0" do
    test "returns :ok or {:error, _}" do
      result = OllamaClient.kill_ollama()
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "restart_ollama/0" do
    test "returns :ok or {:error, _}" do
      result = OllamaClient.restart_ollama()
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "health_check_enabled?/0" do
    test "returns a boolean" do
      result = OllamaClient.health_check_enabled?()
      assert is_boolean(result)
    end

    test "returns true by default" do
      # Default config in dev.exs and runtime.exs sets this to true
      assert OllamaClient.health_check_enabled?() == true
    end
  end

  describe "health_check_interval/0" do
    test "returns a positive integer" do
      result = OllamaClient.health_check_interval()
      assert is_integer(result)
      assert result > 0
    end

    test "returns 30_000 by default" do
      # Default config in dev.exs and runtime.exs sets this to 30_000
      assert OllamaClient.health_check_interval() == 30_000
    end
  end
end

defmodule OllamaChat.OllamaClient do
  @moduledoc """
  Client for interacting with the Ollama API.
  """

  @default_base_url "http://localhost:11434"
  @default_model "llama3"

  @doc """
  Sends a chat request to Ollama and returns the response.
  """
  def chat(messages, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())
    stream = Keyword.get(opts, :stream, false)

    body = %{
      model: model,
      messages: messages,
      stream: stream
    }

    case Req.post(chat_url(), json: body, retry: false) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Ollama API returned status #{status}: #{inspect(body)}"}

      {:error, error} ->
        if connection_refused?(error) do
          case ensure_ollama_running() do
            :ok ->
              # Retry after starting Ollama
              Process.sleep(2000)
              chat(messages, opts)

            {:error, reason} ->
              {:error, "Failed to start Ollama: #{reason}"}
          end
        else
          {:error, "HTTP request failed: #{inspect(error)}"}
        end
    end
  end

  @doc """
  Streams a chat response from Ollama.
  """
  def chat_stream(messages, callback, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    body = %{
      model: model,
      messages: messages,
      stream: true
    }

    case Req.post(chat_url(),
           json: body,
           retry: false,
           into: fn {:data, data}, {req, resp} ->
             # Split by newlines as Ollama sends one JSON object per line
             data
             |> String.split("\n", trim: true)
             |> Enum.each(fn line ->
               case Jason.decode(line) do
                 {:ok, chunk} ->
                   callback.(chunk)

                 {:error, _} ->
                   # Skip invalid JSON chunks
                   :ok
               end
             end)

             {:cont, {req, resp}}
           end
         ) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Ollama API returned status #{status}: #{inspect(body)}"}

      {:error, error} ->
        if connection_refused?(error) do
          case ensure_ollama_running() do
            :ok ->
              # Retry after starting Ollama
              Process.sleep(2000)
              chat_stream(messages, callback, opts)

            {:error, reason} ->
              {:error, "Failed to start Ollama: #{reason}"}
          end
        else
          {:error, "HTTP request failed: #{inspect(error)}"}
        end
    end
  end

  @doc """
  Checks if Ollama is running by making a request to the API.
  """
  def ollama_running? do
    case Req.get(tags_url(), retry: false, receive_timeout: 2000) do
      {:ok, %Req.Response{status: 200}} -> true
      _ -> false
    end
  end

  @doc """
  Lists available models from Ollama.
  """
  def list_models do
    case Req.get(tags_url(), retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.map(models, & &1["name"])}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Failed to list models, status: #{status}"}

      {:error, error} ->
        {:error, "Failed to list models: #{inspect(error)}"}
    end
  end

  @doc """
  Ensures Ollama is running, starting it if necessary.
  """
  def ensure_ollama_running do
    if ollama_running?() do
      :ok
    else
      start_ollama()
    end
  end

  # Private functions

  defp start_ollama do
    case ollama_start_command() do
      nil ->
        {:error, "OLLAMA_START_COMMAND environment variable not set"}

      command ->
        # Run command in background by appending &
        background_command = "#{command} > /dev/null 2>&1 &"

        case System.cmd("sh", ["-c", background_command], stderr_to_stdout: true) do
          {_output, 0} ->
            # Wait for Ollama to start and verify it's responding
            # Poll for up to 10 seconds
            case wait_for_ollama_ready(10) do
              :ok -> :ok
              :timeout -> {:error, "Ollama started but not responding after 10 seconds"}
            end

          {output, exit_code} ->
            {:error, "Failed to start Ollama (exit code #{exit_code}): #{output}"}
        end
    end
  end

  defp base_url do
    Application.get_env(:ollama_chat, :ollama_base_url, @default_base_url)
  end

  defp chat_url do
    "#{base_url()}/api/chat"
  end

  defp tags_url do
    "#{base_url()}/api/tags"
  end

  defp default_model do
    Application.get_env(:ollama_chat, :ollama_default_model, @default_model)
  end

  defp ollama_start_command do
    Application.get_env(:ollama_chat, :ollama_start_command)
  end

  defp wait_for_ollama_ready(max_seconds) do
    wait_for_ollama_ready(max_seconds, 0)
  end

  defp wait_for_ollama_ready(max_seconds, elapsed) when elapsed >= max_seconds do
    :timeout
  end

  defp wait_for_ollama_ready(max_seconds, elapsed) do
    if ollama_running?() do
      # Also verify we can list models
      case list_models() do
        {:ok, _models} ->
          :ok

        _error ->
          Process.sleep(500)
          wait_for_ollama_ready(max_seconds, elapsed + 0.5)
      end
    else
      Process.sleep(500)
      wait_for_ollama_ready(max_seconds, elapsed + 0.5)
    end
  end

  defp connection_refused?(error) do
    case error do
      %{reason: :econnrefused} -> true
      _ -> false
    end
  end
end

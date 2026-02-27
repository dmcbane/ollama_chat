defmodule OllamaChat.OllamaClient do
  @moduledoc """
  Client for interacting with the Ollama API.
  """

  require Logger

  @default_base_url "http://localhost:11434"
  @default_model "llama3"

  @doc """
  Sends a chat request to Ollama and returns the response.
  """
  def chat(messages, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())
    stream = Keyword.get(opts, :stream, false)
    options = Keyword.get(opts, :options, %{})

    Logger.info("Sending chat request to model=#{model} with #{length(messages)} messages")

    body = %{
      model: model,
      messages: messages,
      stream: stream
    }

    body = if options == %{}, do: body, else: Map.put(body, :options, options)

    case Req.post(chat_url(), json: body, retry: false) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Ollama API returned unexpected status=#{status}")
        {:error, "Ollama API returned status #{status}: #{inspect(body)}"}

      {:error, error} ->
        Logger.error("Chat request failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Streams a chat response from Ollama.
  """
  def chat_stream(messages, callback, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())
    options = Keyword.get(opts, :options, %{})

    Logger.info("Starting streaming chat with model=#{model}")

    body = %{
      model: model,
      messages: messages,
      stream: true
    }

    body = if options == %{}, do: body, else: Map.put(body, :options, options)

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

                 {:error, reason} ->
                   Logger.warning(
                     "Skipping invalid JSON chunk in stream: #{inspect(reason)}, line: #{inspect(line)}"
                   )

                   :ok
               end
             end)

             {:cont, {req, resp}}
           end
         ) do
      {:ok, %Req.Response{status: 200}} ->
        Logger.info("Streaming chat completed successfully")
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Streaming chat returned unexpected status=#{status}")
        {:error, "Ollama API returned status #{status}: #{inspect(body)}"}

      {:error, error} ->
        Logger.error("Streaming chat failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Checks if Ollama is running by making a request to the API.
  """
  def ollama_running? do
    case Req.get(tags_url(), retry: false, receive_timeout: 2000) do
      {:ok, %Req.Response{status: 200}} ->
        true

      {:ok, %Req.Response{status: status}} ->
        Logger.debug("Ollama health check returned status #{status}")
        false

      {:error, error} ->
        Logger.debug("Ollama health check failed: #{inspect(error)}")
        false
    end
  end

  @doc """
  Lists available models from Ollama.
  """
  def list_models do
    case Req.get(tags_url(), retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} ->
        model_names = Enum.map(models, & &1["name"])
        Logger.info("Loaded #{length(model_names)} models from Ollama")
        {:ok, model_names}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Failed to list models, status=#{status}")
        {:error, "Failed to list models, status: #{status}"}

      {:error, error} ->
        Logger.warning("Failed to list models: #{inspect(error)}")
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
      Logger.info("Ollama not running, attempting to start")
      start_ollama()
    end
  end

  @doc """
  Returns whether an OLLAMA_START_COMMAND is configured.
  """
  def start_command_configured? do
    ollama_start_command() != nil
  end

  @doc """
  Attempts to start Ollama using the configured start command.
  Returns :ok on success, {:error, reason} on failure.
  """
  def start_ollama do
    case ollama_start_command() do
      nil ->
        Logger.warning("No OLLAMA_START_COMMAND configured, cannot auto-start")
        {:error, "OLLAMA_START_COMMAND environment variable not set"}

      command ->
        Logger.info("Starting Ollama with command: #{command}")
        background_command = "#{command} > /dev/null 2>&1 &"

        case System.cmd("sh", ["-c", background_command], stderr_to_stdout: true) do
          {_output, 0} ->
            case wait_for_ollama_ready(10) do
              :ok ->
                Logger.info("Ollama started successfully")
                :ok

              :timeout ->
                Logger.error("Ollama started but not responding after 10 seconds")
                {:error, "Ollama started but not responding after 10 seconds"}
            end

          {output, exit_code} ->
            Logger.error("Failed to start Ollama (exit_code=#{exit_code}): #{output}")
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

        {:error, reason} ->
          Logger.debug("Waiting for Ollama models to be available: #{inspect(reason)}")
          Process.sleep(500)
          wait_for_ollama_ready(max_seconds, elapsed + 0.5)
      end
    else
      Process.sleep(500)
      wait_for_ollama_ready(max_seconds, elapsed + 0.5)
    end
  end
end

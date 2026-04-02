defmodule OllamaChat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:ollama_chat, OllamaChatWeb.Endpoint)[:http][:port] || 4000

    case check_port_available(port) do
      :ok ->
        :ok

      {:error, :eaddrinuse} ->
        message = """

        \e[31m[error] Could not start server: port #{port} is already in use.\e[0m

        Another instance of Ollama Chat (or another application) is already
        listening on port #{port}. To fix this, either:

          1. Stop the other process using port #{port}:

             lsof -ti:#{port} | xargs kill

          2. Set a different port:

             OLLAMA_CHAT_PORT=#{port + 1} mix phx.server

        """

        IO.puts(message)
        System.halt(1)
    end

    # Parse Ollama URL for Finch pool configuration
    ollama_url = Application.get_env(:ollama_chat, :ollama_base_url, "http://localhost:11434")
    ollama_uri = URI.parse(ollama_url)
    ollama_scheme = String.to_atom(ollama_uri.scheme || "http")
    ollama_host = ollama_uri.host || "localhost"
    ollama_port = ollama_uri.port || 11_434

    # Build Finch pools dynamically to support runtime configuration
    # In Finch 0.21.0+, use URL strings as pool keys
    ollama_pool_url = "#{ollama_scheme}://#{ollama_host}:#{ollama_port}"

    finch_pools = %{
      :default => [size: 50, count: 4],
      ollama_pool_url => [
        size: 100,
        count: 8,
        conn_opts: [timeout: 300_000]
      ]
    }

    children =
      [
        OllamaChatWeb.Telemetry
      ] ++
        maybe_repo() ++
        [
          {DNSCluster, query: Application.get_env(:ollama_chat, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: OllamaChat.PubSub},
          # Finch HTTP client with larger pool for Ollama streaming
          {Finch, name: OllamaChat.Finch, pools: finch_pools},
          # MCP support
          OllamaChat.MCPRegistry,
          OllamaChat.MCPClient,
          # Start to serve requests, typically the last entry
          OllamaChatWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OllamaChat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OllamaChatWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp check_port_available(port) do
    ip = get_listen_ip()

    case :gen_tcp.listen(port, [:binary, ip: ip, reuseaddr: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        # Small delay to ensure OS releases the socket
        Process.sleep(100)
        :ok

      {:error, :eaddrinuse} ->
        {:error, :eaddrinuse}

      {:error, _other} ->
        # Don't block startup for other errors (permissions, etc.)
        # Let Bandit surface those naturally
        :ok
    end
  end

  defp maybe_repo do
    if Application.get_env(:ollama_chat, :memory_enabled, true) do
      [OllamaChat.Repo]
    else
      Logger.info("Memory system disabled — skipping database startup")
      []
    end
  end

  defp get_listen_ip do
    endpoint_config = Application.get_env(:ollama_chat, OllamaChatWeb.Endpoint, [])
    http_config = Keyword.get(endpoint_config, :http, [])
    Keyword.get(http_config, :ip, {127, 0, 0, 1})
  end
end

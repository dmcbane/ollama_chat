defmodule OllamaChat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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

    children = [
      OllamaChatWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:ollama_chat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OllamaChat.PubSub},
      # MCP support
      OllamaChat.MCPRegistry,
      OllamaChat.MCPClient,
      # Start a worker by calling: OllamaChat.Worker.start_link(arg)
      # {OllamaChat.Worker, arg},
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
        :ok

      {:error, :eaddrinuse} ->
        {:error, :eaddrinuse}

      {:error, _other} ->
        # Don't block startup for other errors (permissions, etc.)
        # Let Bandit surface those naturally
        :ok
    end
  end

  defp get_listen_ip do
    endpoint_config = Application.get_env(:ollama_chat, OllamaChatWeb.Endpoint, [])
    http_config = Keyword.get(endpoint_config, :http, [])
    Keyword.get(http_config, :ip, {127, 0, 0, 1})
  end
end

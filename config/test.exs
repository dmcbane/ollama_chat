import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ollama_chat, OllamaChatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rwzpCOEFtKNYFWkj//SGgSB44/MEyJA/l3R61AZ9B9Ggggcvulus20h3m+03wH4q",
  server: false

# In test we don't send emails
config :ollama_chat, OllamaChat.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# MCP config path for tests — use a temp directory to avoid polluting real config
config :ollama_chat,
       :mcp_config_path,
       Path.join(System.tmp_dir!(), "ollama_chat_test/mcp_servers.json")

# Database configuration for tests
# Prevent Memory.Manager from auto-starting so tests can supervise their own instances
config :ollama_chat, :start_memory_manager, false

config :ollama_chat, OllamaChat.Repo,
  database: "ollama_chat_test#{System.get_env("MIX_TEST_PARTITION")}",
  username: System.get_env("OLLAMA_CHAT_DB_USERNAME", "ollama_chat"),
  password: System.get_env("OLLAMA_CHAT_DB_PASSWORD", "ollama_chat"),
  hostname: System.get_env("OLLAMA_CHAT_DB_HOSTNAME", "localhost"),
  port: String.to_integer(System.get_env("OLLAMA_CHAT_DB_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  types: OllamaChat.PostgrexTypes

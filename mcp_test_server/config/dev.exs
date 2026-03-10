import Config

# Development configuration
config :mcp_test_server,
  workspace_path: System.get_env("MCP_WORKSPACE") || Path.expand("../../tmp/mcp_workspace", __DIR__)

# Configure logger for development
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: :debug

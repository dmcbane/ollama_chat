import Config

# Production configuration
config :mcp_test_server,
  workspace_path: System.get_env("MCP_WORKSPACE") || "/var/lib/mcp_workspace"

# Configure logger for production
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: :info

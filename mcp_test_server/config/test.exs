import Config

# Test configuration
config :mcp_test_server,
  workspace_path: Path.expand("../../tmp/mcp_test_workspace", __DIR__)

# Configure logger for testing
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: :warning

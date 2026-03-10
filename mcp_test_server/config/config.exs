import Config

# Configure the workspace path for filesystem operations
# This can be overridden with the MCP_WORKSPACE environment variable
config :mcp_test_server,
  workspace_path: System.get_env("MCP_WORKSPACE") || Path.expand("../tmp/mcp_workspace", __DIR__)

# Configure logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config
import_config "#{config_env()}.exs"

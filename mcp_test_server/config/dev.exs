import Config

# Development configuration
config :mcp_test_server,
  workspace_path: System.get_env("MCP_WORKSPACE") || Path.expand("../../tmp/mcp_workspace", __DIR__)

# Disable logger for MCP stdio server (only JSON-RPC on stdout)
config :logger,
  level: :none

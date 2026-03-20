# This file has been replaced by the multi-server architecture.
#
# Tools are now split into focused server modules:
#
#   McpTestServer.Servers.Filesystem  — file operations (17 tools)
#   McpTestServer.Servers.Memory      — in-memory KV store (4 tools)
#   McpTestServer.Servers.System      — BEAM monitoring, env, utilities (12 tools)
#   McpTestServer.Servers.Web         — web search (1 tool)
#
# The shared JSON-RPC 2.0 / stdio protocol lives in:
#   McpTestServer.StdioServer
#
# Select a server at startup with the MCP_SERVER environment variable:
#   MCP_SERVER=filesystem mix run --no-halt

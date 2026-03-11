# MCP Crash Recovery and Monitoring

This document explains the crash recovery and monitoring features for MCP (Model Context Protocol) servers in Ollama Chat.

## Overview

MCP servers communicate via stdio (standard input/output) and can occasionally crash due to:
- Protocol version mismatches
- Invalid message formats
- Resource exhaustion
- Bugs in the MCP server implementation
- Transient network or system issues

Ollama Chat includes automatic crash recovery with exponential backoff to handle these scenarios gracefully.

## Features

### 1. Automatic Crash Detection

The MCP client manager traps process exits and detects when an MCP server crashes:

```elixir
Process.flag(:trap_exit, true)
```

When a crash occurs, the system:
- Logs detailed crash information
- Identifies which server crashed
- Removes the crashed client from the active pool
- Schedules an automatic restart

### 2. Exponential Backoff Restart Strategy

Crashed servers are automatically restarted with increasing delays:

| Attempt | Delay |
|---------|-------|
| 1 | 1 second |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4 | 8 seconds |
| 5 | 16 seconds |
| 6 | 32 seconds |
| 7+ | 60 seconds (max) |

**Maximum Attempts:** 10 restarts before giving up

### 3. Server Status Monitoring

The UI displays real-time MCP server status:

- **Green dot** - Server is connected and operational
- **Yellow dot (pulsing)** - Server is restarting
- **Red dot** - Server is disconnected (max retries exceeded)

Restart counts are also displayed to help diagnose recurring issues.

### 4. Graceful Degradation

When an MCP server is unavailable:

- Tool calls return a clear error message
- The chat interface remains functional
- Other MCP servers continue to work
- Users are notified when tools are unavailable

## User Experience

### Viewing MCP Server Status

1. Open the chat interface
2. Look for the "MCP Tools" section in the sidebar
3. Click to expand and view:
   - Server connection status
   - Number of available tools
   - Restart counts (if any)
   - Individual tool details

### What You'll See During Recovery

**When a server crashes:**
```
[warning] MCP server crashed: File System (filesystem) - Transport connection failed: Failed to parse handshake response
[info] Will restart File System in 2s (attempt 2/10)
```

**When a server successfully restarts:**
```
[info] Restarted MCP server: File System (attempt 2)
[info] Discovered 4 MCP tools
```

**When a server fails repeatedly:**
```
[error] MCP server File System failed too many times (10 attempts). Giving up.
```

### Status Indicators in UI

The MCP Tools panel shows:

```
Server Status
├─ File System (Dev)        ● Connected (restarted 2x)
├─ Everything (Demo)        ◉ Restarting...
└─ Elixir Test Server       ● Connected
```

## Error Messages

### Common Crash Reasons

#### Transport Connect Failed
```
Transport connection failed: Failed to parse handshake response: invalid message format
```

**Cause:** Protocol version mismatch between ExMCP library and MCP server
**Solution:** Server will auto-restart; if persistent, update MCP server or ExMCP version

#### Normal Shutdown
```
MCP server crashed: filesystem - Normal shutdown
```

**Cause:** Server intentionally shut down
**Solution:** Server will auto-restart normally

#### Process Exit
```
MCP server crashed: filesystem - {exit, reason}
```

**Cause:** Server process terminated unexpectedly
**Solution:** Check server logs; auto-restart will attempt recovery

### Tool Execution Errors

When calling a tool on a crashed/restarting server:

```
MCP server not available (may be restarting)
```

**Action:** Wait a few seconds and try again

When a server crashes during tool execution:

```
MCP server crashed during execution
```

**Action:** Check server status; tool call will need to be retried

## Configuration

### MCP Server Configuration

In `config/dev.exs`:

```elixir
config :ollama_chat, :mcp_servers, [
  %{
    name: :filesystem,
    display_name: "File System (Dev)",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/workspace"],
    enabled: true,
    requires_approval: false
  }
]
```

### Restart Behavior Settings

Current settings (in `OllamaChat.MCPClient`):

```elixir
# Maximum restart attempts before giving up
max_restarts: 10

# Discovery interval (how often to check for new tools)
discovery_interval: 300_000  # 5 minutes

# Status refresh interval (UI updates)
status_refresh: 10_000  # 10 seconds
```

These are currently hardcoded but could be made configurable if needed.

## Monitoring and Diagnostics

### Checking Server Status Programmatically

In IEx console:

```elixir
# Get detailed server information
OllamaChat.MCPClient.server_info()

# Output:
%{
  filesystem: %{
    display_name: "File System (Dev)",
    last_check: ~U[2024-01-15 10:30:00Z],
    pid: "#PID<0.705.0>",
    restart_count: 2,
    status: :connected
  }
}
```

### Log Monitoring

Watch for these log patterns:

```bash
# Successful operations
[info] Started MCP server: File System
[info] Loaded 4 MCP tools
[info] Executing tool: read_file on server: filesystem

# Warnings (handled automatically)
[warning] MCP server crashed: filesystem - Transport connection failed
[info] Will restart File System in 4s (attempt 3/10)

# Errors (require attention)
[error] MCP server File System failed too many times (10 attempts). Giving up.
[error] Failed to restart MCP server: filesystem - {error, :enoent}
```

### Health Checks

The system performs automatic health checks:

- **Tool Discovery:** Every 5 minutes
- **Status Refresh:** Every 10 seconds (when UI is open)
- **On-Demand:** When toggling MCP settings panel

## Troubleshooting

### Server Keeps Crashing

**Problem:** Server crashes repeatedly and hits max retry limit

**Solutions:**

1. **Check server logs:**
   ```bash
   # Look at Phoenix console for detailed error messages
   ```

2. **Verify server installation:**
   ```bash
   npx @modelcontextprotocol/server-filesystem --version
   ```

3. **Test server manually:**
   ```bash
   npx @modelcontextprotocol/server-filesystem /path/to/workspace
   # Should start without errors
   ```

4. **Check workspace permissions:**
   ```bash
   ls -la /path/to/workspace
   chmod 755 /path/to/workspace
   ```

5. **Update MCP server:**
   ```bash
   npm cache clean --force
   npx -y @modelcontextprotocol/server-filesystem@latest
   ```

### Protocol Version Mismatch

**Problem:** "Failed to parse handshake response: invalid message format"

**Cause:** ExMCP library version doesn't match MCP server protocol version

**Solutions:**

1. **Update ExMCP:**
   ```bash
   cd ollama_chat
   mix deps.update ex_mcp
   ```

2. **Pin MCP server version:**
   ```elixir
   # In config/dev.exs
   args: ["-y", "@modelcontextprotocol/server-filesystem@2.0.0", "/path/to/workspace"]
   ```

3. **Check compatibility:**
   - ExMCP 0.8.x supports MCP protocol 2024-11-05 and 2025-11-25
   - Ensure npm MCP servers are compatible versions

### Tools Not Available

**Problem:** "No MCP tools available" shown in UI

**Solutions:**

1. **Check if MCP is enabled:**
   ```elixir
   # In config/dev.exs
   config :ollama_chat, :mcp_enabled, true
   ```

2. **Verify servers are configured:**
   ```elixir
   config :ollama_chat, :mcp_servers, [...]
   ```

3. **Check server status in UI:**
   - Open MCP Tools panel
   - Look for connection status
   - Check for restart attempts

4. **Manually refresh:**
   ```elixir
   # In IEx console
   OllamaChat.MCPClient.refresh_tools()
   ```

### Performance Impact

**Problem:** MCP servers consuming too many resources

**Solutions:**

1. **Disable unused servers:**
   ```elixir
   %{
     name: :filesystem,
     enabled: false,  # Disable this server
     ...
   }
   ```

2. **Reduce discovery interval:**
   ```elixir
   # In MCPClient module
   discovery_interval: 600_000  # Check every 10 minutes instead of 5
   ```

3. **Monitor restart counts:**
   - High restart counts indicate unstable servers
   - Consider removing or fixing problematic servers

## Best Practices

### Development

1. **Enable detailed logging:**
   ```elixir
   config :logger, level: :debug
   ```

2. **Monitor server status regularly:**
   - Check MCP Tools panel periodically
   - Watch for restart counts increasing

3. **Test error scenarios:**
   - Kill MCP server processes manually
   - Verify auto-recovery works
   - Check UI feedback is clear

### Production

1. **Use stable MCP server versions:**
   - Pin specific versions in configuration
   - Test thoroughly before deploying

2. **Monitor logs for patterns:**
   - Set up alerts for repeated crashes
   - Track restart counts over time

3. **Set appropriate timeouts:**
   - Tool execution timeout: 30 seconds (default)
   - Adjust based on tool complexity

4. **Limit enabled servers:**
   - Only enable servers you actually use
   - Each server adds overhead

## Architecture

### Components

```
OllamaChat.Application
└── OllamaChat.MCPClient (GenServer)
    ├── Manages client connections
    ├── Traps EXIT signals
    ├── Schedules restarts with backoff
    ├── Discovers tools periodically
    └── Provides health status

ChatLive (Phoenix LiveView)
├── Displays server status
├── Refreshes status every 10s
├── Shows real-time connection state
└── Handles tool execution errors
```

### State Management

The MCPClient GenServer maintains:

```elixir
%State{
  clients: %{
    server_name: %{
      pid: pid,
      config: server_config,
      status: :connected | :restarting,
      last_health_check: DateTime,
      restart_count: integer
    }
  },
  tools: %{tool_name => tool_info},
  restart_timers: %{server_name => timer_ref}
}
```

## Future Enhancements

Potential improvements for MCP crash recovery:

- [ ] Configurable max restart attempts per server
- [ ] Adjustable backoff strategy (linear, exponential, custom)
- [ ] Health check pings to detect issues before crashes
- [ ] Metrics collection (uptime, crash rate, tool success rate)
- [ ] Alert notifications for repeated failures
- [ ] Circuit breaker pattern for flaky servers
- [ ] Automatic server version detection and compatibility checks
- [ ] Per-server restart strategies
- [ ] Graceful shutdown handling
- [ ] Server dependency management (restart order)

## Related Documentation

- [README.md](../README.md) - Main project documentation
- [PORT_CONFIGURATION.md](PORT_CONFIGURATION.md) - Port and environment setup
- [mcp_test_server/README.md](../mcp_test_server/README.md) - Elixir MCP server
- [ExMCP Documentation](https://hexdocs.pm/ex_mcp) - MCP client library

## Support

If you encounter persistent MCP server crashes:

1. Check the troubleshooting section above
2. Review logs for detailed error messages
3. Verify server and ExMCP versions are compatible
4. Test the MCP server independently
5. Report issues with full logs and configuration

## Summary

The MCP crash recovery system provides:

- ✅ Automatic detection of crashed servers
- ✅ Exponential backoff restart strategy
- ✅ Real-time status monitoring in UI
- ✅ Graceful degradation when servers fail
- ✅ Detailed logging for diagnostics
- ✅ Protection against infinite restart loops
- ✅ Minimal impact on user experience

MCP servers can crash for various reasons, but the recovery system ensures that Ollama Chat remains stable and usable even when individual MCP servers encounter issues.
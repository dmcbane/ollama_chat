# MCP Crash Recovery Implementation Summary

## Overview

This document summarizes the implementation of automatic crash recovery and monitoring for MCP (Model Context Protocol) servers in Ollama Chat.

## Problem Statement

MCP servers communicate via stdio and can crash due to:
- Protocol version mismatches between ExMCP library and npm MCP servers
- Invalid message format errors during handshake or communication
- Resource exhaustion or transient system issues
- Bugs in MCP server implementations

Previously, when an MCP server crashed, it would remain unavailable until the entire application was restarted.

## Solution Implemented

### 1. Automatic Crash Detection and Recovery

**File:** `lib/ollama_chat/mcp_client.ex`

**Key Features:**
- Process exit trapping to detect crashed MCP servers
- Automatic identification of which server crashed
- Removal of crashed clients from the active pool
- Scheduled automatic restart with exponential backoff

**Implementation Details:**
```elixir
# Trap exits to handle crashed processes
Process.flag(:trap_exit, true)

# Handle EXIT signals
def handle_info({:EXIT, pid, reason}, state) do
  # Find crashed server, log details, schedule restart
end
```

### 2. Exponential Backoff Strategy

**Restart Schedule:**
| Attempt | Delay | Formula |
|---------|-------|---------|
| 1 | 1s | base × 2^0 |
| 2 | 2s | base × 2^1 |
| 3 | 4s | base × 2^2 |
| 4 | 8s | base × 2^3 |
| 5 | 16s | base × 2^4 |
| 6 | 32s | base × 2^5 |
| 7+ | 60s | max cap |

**Configuration:**
- Base delay: 1000ms
- Max delay: 60000ms (1 minute)
- Max attempts: 10 restarts before giving up

**Benefits:**
- Prevents restart storms
- Gives servers time to recover
- Reduces log spam
- Protects system resources

### 3. Enhanced Error Handling

**Tool Execution Protection:**
```elixir
# Check if server is available
case Map.get(state.clients, tool_info.server) do
  nil -> {:error, "MCP server not available (may be restarting)"}
  client_info -> execute_tool(...)
end

# Catch crashes during execution
try do
  Client.call_tool(...)
catch
  :exit, reason -> {:error, "MCP server crashed during execution"}
end
```

**Server Startup Protection:**
```elixir
try do
  Client.start_link(...)
rescue
  error -> {:error, error}
catch
  :exit, reason -> {:error, reason}
end
```

### 4. Real-Time Status Monitoring

**File:** `lib/ollama_chat_web/live/chat_live.ex`

**UI Components:**
- Server status indicators (green/yellow/red dots)
- Restart count display
- Real-time status updates every 10 seconds
- On-demand refresh when opening MCP panel

**Status Display:**
```
Server Status
├─ File System (Dev)        ● Connected (restarted 2x)
├─ Everything (Demo)        ◉ Restarting...
└─ Elixir Test Server       ● Connected
```

**Visual Feedback:**
- **Green dot** → Server connected and operational
- **Yellow dot (pulsing)** → Server is restarting
- **Red dot** → Server disconnected (max retries exceeded)
- **Restart count** → Shows stability issues

### 5. Comprehensive Logging

**Crash Detection:**
```
[warning] MCP server crashed: File System (filesystem) - Transport connection failed: Failed to parse handshake response
[info] Will restart File System in 4s (attempt 3/10)
```

**Successful Recovery:**
```
[info] Restarted MCP server: File System (attempt 3)
[info] Discovered 4 MCP tools
```

**Permanent Failure:**
```
[error] MCP server File System failed too many times (10 attempts). Giving up.
```

**Formatted Crash Reasons:**
- Transport connection failures
- Normal shutdowns
- Abnormal exits
- Other error types

### 6. New API Functions

**Added to `OllamaChat.MCPClient`:**

```elixir
@spec server_info() :: map()
def server_info()
# Returns detailed server status including restart counts

@spec health_status() :: map()
def health_status()
# Returns health status of all MCP servers

@spec refresh_tools() :: :ok
def refresh_tools()
# Forces immediate tool rediscovery
```

## Files Modified

### Core Implementation
- `lib/ollama_chat/mcp_client.ex` (+250 lines)
  - Added crash detection and recovery logic
  - Implemented exponential backoff
  - Enhanced error handling
  - Added status reporting

### UI Updates
- `lib/ollama_chat_web/live/chat_live.ex` (+80 lines)
  - Added server status display
  - Implemented periodic status refresh
  - Enhanced MCP tools panel
  - Added visual status indicators

### Documentation
- `docs/MCP_CRASH_RECOVERY.md` (new, 473 lines)
  - Comprehensive crash recovery guide
  - Troubleshooting procedures
  - Configuration options
  - Best practices

- `docs/CHANGES_MCP_RECOVERY.md` (this file)
  - Implementation summary
  - Technical details

## State Management

### New State Fields

**MCPClient State:**
```elixir
defmodule State do
  defstruct clients: %{},
            tools: %{},
            last_discovery: nil,
            discovery_interval: 300_000,
            restart_timers: %{}  # NEW
end

# Client info structure enhanced:
%{
  pid: pid,
  config: server_config,
  status: :connected | :restarting,
  last_health_check: DateTime,
  restart_count: 0  # NEW - tracks restart attempts
}
```

**ChatLive Assigns:**
```elixir
socket
|> assign(:mcp_enabled?, boolean)
|> assign(:mcp_tools, map)
|> assign(:mcp_server_status, map)  # NEW - server status info
|> assign(:show_mcp_settings, boolean)
```

## Behavior Changes

### Before Implementation
- MCP server crashes → permanent unavailability
- No visibility into server health
- Manual restart required (full app restart)
- Tool calls fail silently
- No recovery mechanism

### After Implementation
- MCP server crashes → automatic restart with backoff
- Real-time status monitoring in UI
- Automatic recovery (up to 10 attempts)
- Tool calls return clear error messages
- Graceful degradation
- User feedback on server health

## Error Messages

### User-Facing Errors

**Server Unavailable:**
```
MCP server not available (may be restarting)
```
→ Clear indication that server is recovering

**Server Crashed During Execution:**
```
MCP server crashed during execution
```
→ Informs user to retry

### Developer Logs

**Detailed Crash Info:**
```
[warning] MCP server crashed: filesystem - Transport connection failed: Failed to parse handshake response: invalid message format
```

**Recovery Progress:**
```
[info] Scheduling restart for File System in 8s (attempt 4/10)
[info] Restarted MCP server: File System (attempt 4)
```

**Permanent Failure:**
```
[error] MCP server File System failed too many times (10 attempts). Giving up.
```

## Testing Scenarios

### Manual Testing

1. **Normal Crash Recovery:**
   - Kill MCP server process manually
   - Verify auto-restart occurs
   - Check UI shows status changes
   - Confirm tools become available again

2. **Repeated Crashes:**
   - Configure invalid MCP server
   - Verify exponential backoff
   - Confirm max attempts honored
   - Check error logging

3. **Tool Execution During Restart:**
   - Trigger server crash
   - Attempt tool call during restart
   - Verify error message is clear
   - Retry after recovery succeeds

4. **UI Updates:**
   - Open MCP Tools panel
   - Crash a server
   - Verify status indicator changes
   - Confirm restart count updates

### Expected Behavior

✅ Server crashes are detected immediately
✅ Restart happens automatically with backoff
✅ UI shows accurate real-time status
✅ Tool calls handle unavailable servers gracefully
✅ Logs provide clear diagnostic information
✅ Chat functionality remains unaffected
✅ Other MCP servers continue working
✅ Max restart limit prevents infinite loops

## Performance Impact

### Minimal Overhead
- Process monitoring: negligible CPU/memory
- Status checks: 10-second interval (only when UI open)
- Tool discovery: 5-minute interval (unchanged)
- Restart timers: only created when needed

### Resource Protection
- Exponential backoff prevents restart storms
- Max attempts limit (10) prevents infinite loops
- Timers cleaned up after successful restart
- No memory leaks from crashed processes

## Configuration

### Current Defaults
```elixir
# In OllamaChat.MCPClient
max_restarts: 10
discovery_interval: 300_000  # 5 minutes
status_refresh: 10_000       # 10 seconds (UI)
base_backoff: 1_000          # 1 second
max_backoff: 60_000          # 60 seconds
```

### Future Configurability
These could be made configurable via environment variables or config files if needed:
- `MCP_MAX_RESTARTS`
- `MCP_DISCOVERY_INTERVAL`
- `MCP_STATUS_REFRESH`
- `MCP_RESTART_BACKOFF`

## Known Issues and Limitations

### Current Limitations

1. **Protocol Version Compatibility:**
   - ExMCP 0.8.3 vs npm MCP servers may have version mismatches
   - Some servers send messages in unexpected formats
   - Workaround: Auto-restart usually resolves after server initializes

2. **Restart Count Persistence:**
   - Restart counts reset if entire app restarts
   - Not persisted to disk
   - Impact: minimal, provides session-based stability info

3. **Max Restart Limit:**
   - After 10 failures, server stays down until manual intervention
   - Could add "reset" button in future
   - Impact: rare, only affects persistently broken servers

### Not Issues

❌ **MCP servers using network ports** - They don't; they use stdio
❌ **Port conflicts** - Not applicable to MCP servers
❌ **Database persistence** - Not needed for recovery state

## Future Enhancements

### Potential Improvements

1. **Circuit Breaker Pattern:**
   - Track failure rates
   - Temporarily disable flaky servers
   - Automatically re-enable after cooldown

2. **Health Checks:**
   - Proactive ping/pong before crashes
   - Detect unresponsive servers early
   - Graceful shutdown handling

3. **Metrics and Analytics:**
   - Uptime tracking per server
   - Tool success/failure rates
   - Crash pattern analysis
   - Performance metrics

4. **Configuration UI:**
   - Enable/disable servers from UI
   - Adjust restart strategies
   - View historical crash logs
   - Manual restart/reset buttons

5. **Advanced Restart Strategies:**
   - Per-server max attempts
   - Custom backoff algorithms
   - Dependency-aware restart order
   - Conditional restart based on error type

6. **Notifications:**
   - User alerts for repeated failures
   - Admin notifications
   - Slack/email integration
   - Status webhooks

## Migration Guide

### For Existing Deployments

No migration needed! Changes are backward compatible:

✅ Existing MCP server configurations work unchanged
✅ No database migrations required
✅ No config file updates needed
✅ Automatic activation on next deployment

### Optional Enhancements

1. **Update MCP servers to latest versions:**
   ```bash
   npx -y @modelcontextprotocol/server-filesystem@latest
   ```

2. **Monitor logs after deployment:**
   ```bash
   tail -f log/dev.log | grep -i mcp
   ```

3. **Check server status in UI:**
   - Open MCP Tools panel
   - Verify all servers show green dots
   - Check for restart counts

## Rollback Plan

If issues arise, rollback is straightforward:

1. **Revert code changes:**
   ```bash
   git revert <commit-hash>
   ```

2. **Key files to revert:**
   - `lib/ollama_chat/mcp_client.ex`
   - `lib/ollama_chat_web/live/chat_live.ex`

3. **Cleanup:**
   ```bash
   mix deps.get
   mix compile
   mix phx.server
   ```

Previous behavior: MCP servers crash and stay down (no recovery).

## Success Metrics

### How to Measure Success

1. **Reduced Manual Restarts:**
   - Track how often devs need to restart app due to MCP issues
   - Target: 90% reduction

2. **Server Uptime:**
   - Monitor MCP server availability over time
   - Target: >95% uptime (including auto-recovery time)

3. **User Experience:**
   - Tool call success rate
   - Error message clarity
   - Time to recovery after crash

4. **Log Quality:**
   - Clear diagnostic information
   - Actionable error messages
   - Reduced support tickets

## Related Changes

This implementation complements the earlier port configuration updates:

- Port configuration: Clarified that MCP servers use stdio (not ports)
- Documentation: Updated to explain MCP communication method
- Error messages: Improved clarity around connection issues

See also:
- `docs/PORT_CONFIGURATION.md`
- `docs/CHANGES_PORT_CONFIG.md`

## Conclusion

The MCP crash recovery implementation provides:

✅ **Automatic Recovery** - No manual intervention needed for transient crashes
✅ **Smart Backoff** - Exponential delays prevent resource exhaustion
✅ **Real-Time Monitoring** - Visual status indicators in UI
✅ **Graceful Degradation** - Chat remains functional even when MCP servers fail
✅ **Detailed Logging** - Clear diagnostic information for debugging
✅ **Protection** - Max attempts prevent infinite restart loops
✅ **User Feedback** - Clear error messages and status displays

This makes Ollama Chat more robust and production-ready when using MCP servers.

## Date

2024-12-19

## Author

Crash recovery and monitoring implementation for MCP servers.
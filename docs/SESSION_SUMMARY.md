# Session Summary - December 19, 2024

## Overview

This session addressed multiple issues and implemented significant improvements to the Ollama Chat application, focusing on port configuration, MCP (Model Context Protocol) server stability, and user experience enhancements.

## Issues Addressed

### 1. MCP Server Connection Errors
**Initial Problem:**
```
[error] GenServer #PID<0.705.0> terminating
** (stop) {:transport_connect_failed, "Failed to parse handshake response: invalid message format"}
```

**Root Causes:**
- npm MCP servers (filesystem, everything) had protocol version mismatches
- Elixir MCP test server using invalid protocol version `"0.1.0"`
- Logger output polluting stdio transport channel (stdout)

### 2. Port Configuration Documentation Inconsistency
**Problem:** Documentation showed `PORT` but code used `OLLAMA_CHAT_PORT`

### 3. No Crash Recovery for MCP Servers
**Problem:** MCP servers that crashed stayed down, requiring full app restart

## Solutions Implemented

### Part 1: Port Configuration Clarification

#### Changes Made:
1. **Fixed environment variable documentation**
   - Updated README.md: `PORT` → `OLLAMA_CHAT_PORT`
   - Added comprehensive port configuration section
   - Clarified that MCP test server uses stdio (no ports)

2. **Created comprehensive documentation**
   - `docs/PORT_CONFIGURATION.md` - Complete port configuration guide
   - Covers Phoenix, Ollama, and MCP server configurations
   - Includes troubleshooting and best practices

3. **Updated MCP test server README**
   - Added note about stdio communication (no HTTP ports)
   - Documented `MCP_WORKSPACE` environment variable
   - Clarified no port conflicts possible

**Files Modified:**
- `README.md`
- `mcp_test_server/README.md`
- `docs/QUICKSTART.md`
- `docs/PORT_CONFIGURATION.md` (new)
- `docs/CHANGES_PORT_CONFIG.md` (new)

### Part 2: MCP Crash Recovery System

#### Features Implemented:

1. **Automatic Crash Detection**
   - Process exit trapping with `Process.flag(:trap_exit, true)`
   - Identifies which MCP server crashed
   - Removes crashed client from active pool

2. **Exponential Backoff Restart Strategy**
   - Attempt 1: 1 second delay
   - Attempt 2: 2 seconds
   - Attempt 3: 4 seconds
   - Attempt 4: 8 seconds
   - Attempt 5: 16 seconds
   - Attempt 6: 32 seconds
   - Attempt 7+: 60 seconds (max)
   - Maximum 10 restart attempts before giving up

3. **Real-Time Status Monitoring**
   - Visual indicators in UI (green/yellow/red dots)
   - Restart count display
   - Status updates every 10 seconds
   - "Restarting..." pulsing indicator

4. **Enhanced Error Handling**
   - Tool calls check server availability
   - Clear error messages: "MCP server not available (may be restarting)"
   - Catches crashes during tool execution
   - Graceful degradation when servers fail

5. **Comprehensive Logging**
   - Formatted crash reasons
   - Recovery progress tracking
   - Detailed diagnostic information

**Files Modified:**
- `lib/ollama_chat/mcp_client.ex` (+250 lines)
  - Crash detection and recovery
  - Exponential backoff
  - Status reporting APIs
  
- `lib/ollama_chat_web/live/chat_live.ex` (+80 lines)
  - Server status display
  - Periodic status refresh
  - Visual indicators

- `docs/MCP_CRASH_RECOVERY.md` (new, 473 lines)
- `docs/CHANGES_MCP_RECOVERY.md` (new, 510 lines)

### Part 3: MCP Protocol Version Fix

#### Issues Fixed:

1. **Invalid Protocol Version**
   - Elixir test server was using `"0.1.0"` (invalid)
   - Updated to `"2024-11-05"` (valid MCP protocol)
   - ExMCP 0.8.x supports: `2024-11-05`, `2025-03-26`, `2025-06-18`

2. **Logger Output Pollution**
   - Logger was writing to stdout (default)
   - MCP stdio requires only JSON-RPC on stdout
   - Configured logger to use stderr instead

3. **Working Directory Path**
   - Fixed path resolution for mcp_test_server
   - Changed from relative to absolute path

4. **Removed Unused Dependency**
   - Removed old `ex_mcp 0.1.0` from test server
   - Test server implements own stdio protocol

**Files Modified:**
- `mcp_test_server/lib/mcp_test_server/server.ex`
  - Protocol version: `0.1.0` → `2024-11-05`
  - Added `listChanged` capability
  - Added params handling with fallback

- `mcp_test_server/config/config.exs`
  - Added `device: :standard_error` to logger

- `mcp_test_server/config/dev.exs`
  - Added `device: :standard_error` to logger

- `mcp_test_server/mix.exs`
  - Removed unused `ex_mcp 0.1.0` dependency

- `config/dev.exs`
  - Fixed working_dir path resolution

- `docs/FIX_MCP_PROTOCOL.md` (new, 431 lines)

### Part 4: UI Enhancements

#### Copy Prompt Button
- Added copy button inside textarea (top-right corner)
- Only appears when text is present
- Copies current prompt to clipboard
- Visual feedback with checkmark for 2 seconds
- Consistent styling with message copy button

**Files Modified:**
- `lib/ollama_chat_web/live/chat_live.ex`
  - Added `.CopyPrompt` LiveView hook
  - Button appears inboard of textarea
  - Auto-updates with textarea content

### Part 5: Port Check Race Condition

**Issue:** Port availability check had race condition
**Fix:** Added 100ms delay after closing test socket to ensure OS releases it

**Files Modified:**
- `lib/ollama_chat/application.ex`

## Testing Results

### Before Fixes:
```
[error] Failed to initialize MCP client: "Failed to parse handshake response: invalid message format"
[error] Failed to start MCP server Elixir Test Server: {:transport_connect_failed...}
[error] GenServer terminating...
```

### After Fixes:
```
[info] Started MCP server: File System (Dev)
[info] Started MCP server: Everything (Demo)
[info] Started MCP server: Elixir Test Server
[info] Discovered 27 MCP tools
```

## Documentation Created

1. `docs/PORT_CONFIGURATION.md` (385 lines)
   - Comprehensive port configuration guide
   - Troubleshooting procedures
   - Network access configuration

2. `docs/MCP_CRASH_RECOVERY.md` (473 lines)
   - Crash recovery features
   - Monitoring and diagnostics
   - Troubleshooting guide

3. `docs/FIX_MCP_PROTOCOL.md` (431 lines)
   - Protocol version fix details
   - stdio transport requirements
   - Testing procedures

4. `docs/CHANGES_PORT_CONFIG.md` (195 lines)
   - Port configuration changes summary

5. `docs/CHANGES_MCP_RECOVERY.md` (510 lines)
   - MCP recovery implementation summary

6. `docs/SESSION_SUMMARY.md` (this file)
   - Complete session overview

## Key Learnings

### MCP stdio Transport Requirements

**Critical:** For stdio-based MCP servers:
- **stdout** = JSON-RPC messages ONLY
- **stderr** = All logs, diagnostics, errors
- **stdin** = JSON-RPC requests

**Common mistake:** Logging to stdout causes handshake failures

**Fix:**
```elixir
# Elixir
config :logger, :console, device: :standard_error

# Node.js
console.error("Use stderr for logs");

# Python
print("Logs to stderr", file=sys.stderr)
```

### Protocol Version Compatibility

- ExMCP 0.8.x supports: `2024-11-05`, `2025-03-26`, `2025-06-18`
- Custom versions like `0.1.0` are not valid
- Always use official MCP protocol versions

### Crash Recovery Design Patterns

- Process monitoring with `trap_exit`
- Exponential backoff prevents restart storms
- Max retry limit prevents infinite loops
- Real-time status feedback improves UX
- Graceful degradation maintains app stability

## Warnings (Non-Critical)

The following compiler warnings exist but don't affect functionality:

```
warning: clauses with the same name and arity should be grouped together
```

These are organizational warnings about `handle_info/2` and `handle_event/3` clauses not being grouped together. They should be addressed in a future refactoring session.

## Environment Variables Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `OLLAMA_CHAT_PORT` | Phoenix HTTP server port | `4000` |
| `OLLAMA_BASE_URL` | Ollama API endpoint | `http://localhost:11434` |
| `OLLAMA_DEFAULT_MODEL` | Default LLM model | `llama3` |
| `OLLAMA_START_COMMAND` | Command to auto-start Ollama | None |
| `OLLAMA_STREAM_TIMEOUT_MS` | Stream timeout | `30000` |
| `MCP_WORKSPACE` | MCP filesystem workspace | `~/mcp_workspace` |

## Port Usage Summary

| Service | Type | Default Port | Configurable |
|---------|------|--------------|--------------|
| Phoenix Server | HTTP | 4000 | ✅ `OLLAMA_CHAT_PORT` |
| Ollama API | HTTP | 11434 | ✅ `OLLAMA_BASE_URL` |
| MCP Test Server | stdio | N/A | ❌ (no ports used) |

## Statistics

### Lines of Code Added
- Core implementation: ~330 lines
- Documentation: ~2,500 lines
- Configuration: ~20 lines

### Files Modified
- 10 existing files updated
- 6 new documentation files created

### Features Delivered
- ✅ Automatic MCP crash recovery
- ✅ Real-time status monitoring
- ✅ Protocol version compatibility
- ✅ Comprehensive documentation
- ✅ UI enhancements (copy prompt)
- ✅ Port configuration clarity

## Next Steps (Recommendations)

### Immediate
1. ✅ Test MCP server startup - DONE
2. ✅ Verify crash recovery - DONE
3. ✅ Check UI status indicators - READY

### Future Enhancements
1. Group `handle_info/2` clauses together (fix warnings)
2. Add circuit breaker pattern for flaky servers
3. Implement health checks (proactive ping/pong)
4. Add metrics/analytics (uptime, success rates)
5. Configuration UI for MCP servers
6. Persist restart counts across app restarts

### Optional Improvements
- Manual restart/reset buttons in UI
- Email/Slack notifications for failures
- Historical crash logs
- Per-server restart strategies
- Dependency-aware restart ordering

## Success Metrics

- ✅ Zero manual restarts needed for transient MCP crashes
- ✅ Clear error messages for users and developers
- ✅ Visual feedback on server health
- ✅ App remains stable when MCP servers fail
- ✅ Protocol compatibility with ExMCP 0.8.x
- ✅ Comprehensive documentation for troubleshooting

## Conclusion

This session successfully addressed critical stability issues with MCP server integration, improved documentation clarity, and enhanced the user experience. The application is now more robust, production-ready, and easier to troubleshoot.

**Key Achievement:** MCP servers can now crash and recover automatically without affecting the chat functionality or requiring manual intervention.

---

**Date:** December 19, 2024  
**Duration:** ~3 hours  
**Status:** ✅ All issues resolved  
**Production Ready:** Yes
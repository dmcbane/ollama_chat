# Port Configuration Changes Summary

## Overview

This document summarizes the changes made to clarify port configuration and environment variables for Ollama Chat and the MCP test server.

## Changes Made

### 1. Documentation Updates

#### README.md
- **Fixed:** Changed `PORT` to `OLLAMA_CHAT_PORT` in environment variables table
- **Added:** New "Port Configuration" section explaining:
  - Phoenix Server uses port 4000 (configurable via `OLLAMA_CHAT_PORT`)
  - Ollama API uses port 11434 (configurable via `OLLAMA_BASE_URL`)
  - MCP Test Server uses stdio (no port, cannot conflict)
- **Added:** `MCP_WORKSPACE` to environment variables table

#### mcp_test_server/README.md
- **Added:** Note at the top clarifying stdio communication (no HTTP ports)
- **Added:** Environment Variables section documenting `MCP_WORKSPACE`
- **Added:** Note that MCP test server doesn't use `OLLAMA_CHAT_PORT`
- **Updated:** Integration section to clarify no port conflicts possible
- **Removed:** Unnecessary manual start instructions (auto-started by Ollama Chat)

#### docs/QUICKSTART.md
- **Fixed:** Changed `PORT=4001` to `OLLAMA_CHAT_PORT=4001` in troubleshooting
- **Added:** Note explaining MCP server uses stdio and cannot conflict

#### docs/PORT_CONFIGURATION.md (NEW)
- **Created:** Comprehensive guide covering:
  - Port usage overview table
  - Phoenix server port configuration
  - Ollama API port configuration
  - MCP server stdio communication
  - Troubleshooting port conflicts
  - Network access configuration
  - Environment variables reference
  - Best practices for dev/prod/test
  - Examples and testing procedures

### 2. Code Changes

#### lib/ollama_chat_web/live/chat_live.ex
- **Added:** Copy button for prompt textarea
- **Feature:** Button appears inside textarea (top-right corner) when text is present
- **Feature:** Copies current prompt text to clipboard
- **Feature:** Visual feedback with checkmark for 2 seconds
- **Implementation:** New `.CopyPrompt` LiveView hook
- **Styling:** Consistent with existing copy message button

### 3. Configuration Already Correct

The following were already correctly configured (no changes needed):

- `config/runtime.exs` - Uses `OLLAMA_CHAT_PORT` (not `PORT`)
- `lib/ollama_chat/application.ex` - Error message shows `OLLAMA_CHAT_PORT`
- `CLAUDE.md` - Already documented `OLLAMA_CHAT_PORT`

## Key Clarifications

### Port Usage

| Service | Type | Default Port | Environment Variable |
|---------|------|--------------|---------------------|
| Phoenix Server | HTTP | 4000 | `OLLAMA_CHAT_PORT` |
| Ollama API | HTTP | 11434 | `OLLAMA_BASE_URL` |
| MCP Test Server | stdio | N/A | N/A |

### Important Points

1. **MCP Test Server Does Not Use Ports**
   - Communicates via stdio (standard input/output)
   - Cannot conflict with Phoenix server or Ollama
   - No port configuration needed

2. **Consistent Environment Variable Names**
   - Use `OLLAMA_CHAT_PORT` (not `PORT`)
   - Use `OLLAMA_BASE_URL` for Ollama endpoint
   - Use `MCP_WORKSPACE` for MCP filesystem operations

3. **No Port Conflicts**
   - Phoenix and Ollama use different default ports
   - MCP server doesn't use ports at all
   - Multiple instances can run with different port configurations

## Usage Examples

### Change Phoenix Server Port

```bash
OLLAMA_CHAT_PORT=4001 mix phx.server
```

### Change Ollama API URL

```bash
OLLAMA_BASE_URL=http://localhost:8080 mix phx.server
```

### Configure MCP Workspace

```bash
MCP_WORKSPACE=/path/to/workspace mix phx.server
```

### Example .env File

```bash
# Phoenix Server
OLLAMA_CHAT_PORT=4000

# Ollama API
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_DEFAULT_MODEL=qwen2.5:7b-instruct
OLLAMA_START_COMMAND=/usr/local/bin/ollama serve

# MCP
MCP_WORKSPACE=~/mcp_workspace
```

## Testing

### Verify Port Configuration

```bash
# Start with custom port
OLLAMA_CHAT_PORT=4001 mix phx.server

# Test in another terminal
curl http://localhost:4001
```

### Verify Ollama Connection

```bash
curl http://localhost:11434/api/tags
```

### Check Active Ports

```bash
lsof -iTCP -sTCP:LISTEN -n -P | grep -E "(4000|11434)"
```

## Migration Guide

If you were using `PORT` instead of `OLLAMA_CHAT_PORT`:

### Before (incorrect)
```bash
PORT=4000 mix phx.server
```

### After (correct)
```bash
OLLAMA_CHAT_PORT=4000 mix phx.server
```

### Update .env Files

Replace any instances of `PORT=` with `OLLAMA_CHAT_PORT=` in your `.env` files.

## Benefits

1. **Clarity:** Clear documentation about what uses ports and what doesn't
2. **Consistency:** All docs now use the correct `OLLAMA_CHAT_PORT` variable
3. **No Conflicts:** Explicitly documented that MCP server cannot conflict
4. **Comprehensive:** New PORT_CONFIGURATION.md covers all scenarios
5. **User-Friendly:** Copy button makes it easier to reuse prompts

## Files Modified

- `README.md` - Fixed variable name, added port configuration section
- `mcp_test_server/README.md` - Added stdio clarification
- `docs/QUICKSTART.md` - Fixed variable name in troubleshooting
- `lib/ollama_chat_web/live/chat_live.ex` - Added copy prompt button
- `docs/PORT_CONFIGURATION.md` - New comprehensive guide (created)
- `docs/CHANGES_PORT_CONFIG.md` - This file (created)

## Related Documentation

- [README.md](../README.md) - Main project documentation
- [QUICKSTART.md](QUICKSTART.md) - Quick start guide
- [PORT_CONFIGURATION.md](PORT_CONFIGURATION.md) - Detailed port guide
- [mcp_test_server/README.md](../mcp_test_server/README.md) - MCP server docs
- [CLAUDE.md](../CLAUDE.md) - Claude Code guidance

## Date

2024-12-XX (Update with actual date)

## Author

Documentation and code improvements for port configuration clarity.
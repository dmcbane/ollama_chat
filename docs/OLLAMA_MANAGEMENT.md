# Ollama Server Management

This document describes the Ollama server management features available in the chat interface.

## Overview

The application provides built-in controls to start, restart, and kill the Ollama server process directly from the UI. This is particularly useful when dealing with:

- Runaway streaming responses that won't stop
- Hung or unresponsive Ollama processes
- Need to reset Ollama state without accessing a terminal
- Testing or development scenarios

## Prerequisites

These features require the `OLLAMA_START_COMMAND` environment variable to be set. See `.env.example` for configuration details.

## UI Controls

All controls appear in the top-left status bar, next to the connection status indicator:

### Connection Status Indicator

A colored dot shows the current Ollama status:
- 🟢 **Green (pulsing)** - Connected and running
- 🔴 **Red** - Disconnected/stopped
- 🟡 **Yellow** - Unknown/checking

### Start Button

**Appearance:** Green button with play icon  
**When visible:** When Ollama is stopped  
**Action:** Starts the Ollama server using the configured start command  

### Restart Button

**Appearance:** Yellow button with circular arrow icon  
**When visible:** When Ollama is running  
**Tooltip:** "Restart Ollama (useful for runaway responses)"  
**Action:** 
1. Kills the Ollama process
2. Waits 1 second for graceful termination
3. Starts Ollama again using the start command
4. Reloads available models

**Use when:**
- A streaming response won't stop despite clicking Cancel
- Ollama seems hung or unresponsive
- Need to reset Ollama's internal state

### Kill Button

**Appearance:** Red button with X-circle icon  
**When visible:** When Ollama is running  
**Tooltip:** "Kill Ollama process"  
**Action:**
1. Force-kills the Ollama process (`pkill -9 ollama`)
2. Cancels any active streaming operations
3. Updates status to "stopped"

**Use when:**
- Need to immediately stop Ollama without restarting
- Ollama is consuming too many resources
- Want to manually restart later
- Testing error recovery

## Technical Details

### Backend Implementation

**Module:** `OllamaChat.OllamaClient`

#### Functions

**`kill_ollama/0`**
- Executes: `pkill -9 ollama`
- Returns: `:ok` on success, `{:error, reason}` on failure
- Exit code 0 or 1 treated as success (1 means no process found)

**`restart_ollama/0`**
- Calls `kill_ollama()`
- Sleeps for 1000ms
- Calls `start_ollama()`
- Returns: `:ok` on success, `{:error, reason}` on failure

**`start_ollama/0`** (existing)
- Executes the configured `OLLAMA_START_COMMAND`
- Runs in background: `command > /dev/null 2>&1 &`
- Waits up to 10 seconds for Ollama to be ready
- Returns: `:ok` on success, `{:error, reason}` on failure

### Frontend Implementation

**Module:** `OllamaChatWeb.ChatLive`

#### Event Handlers

**`handle_event("restart_ollama", ...)`**
- Sets status: "Restarting Ollama..."
- Cancels active streams
- Spawns background process for restart
- Non-blocking UI operation

**`handle_event("kill_ollama", ...)`**
- Sets status: "Killing Ollama process..."
- Cancels active streams
- Spawns background process for kill
- Non-blocking UI operation

#### Info Handlers

**`handle_info({:restart_success}, ...)`**
- Updates status to "running"
- Shows success message for 3 seconds
- Reloads model list
- Clears streaming state

**`handle_info({:restart_failed, reason}, ...)`**
- Updates status to "stopped"
- Shows error message
- Stops recovery state

**`handle_info({:kill_success}, ...)`**
- Updates status to "stopped"
- Shows success message for 3 seconds
- Clears streaming state

**`handle_info({:kill_failed, reason}, ...)`**
- Shows error message
- Maintains current state

## Error Handling

All operations include comprehensive error handling:

1. **Permission errors** - If user lacks permission to kill processes
2. **Process not found** - Treated as success for kill operations
3. **Start failures** - Detailed error messages with exit codes
4. **Timeout errors** - When Ollama doesn't respond after starting

Error messages are displayed in the UI and logged to the console.

## Security Considerations

- **Process isolation:** Only kills processes named "ollama"
- **No shell injection:** Commands use `System.cmd` with argument arrays
- **Workspace protection:** No file system access beyond process management
- **User control:** All operations require explicit button clicks

## Configuration

Set in `.env` file:

```bash
# Command to start Ollama (required for start/restart)
OLLAMA_START_COMMAND="ollama serve"

# Or with custom options
OLLAMA_START_COMMAND="OLLAMA_HOST=0.0.0.0 ollama serve"
```

Without `OLLAMA_START_COMMAND`, only the kill button will work (restart requires starting).

## Troubleshooting

### Buttons don't appear
- **Check:** Is `OLLAMA_START_COMMAND` set in `.env`?
- **Check:** Is Ollama running? Start button only shows when stopped
- **Check:** Restart/Kill buttons only show when running

### Restart fails
- **Check:** Does the configured command work from terminal?
- **Check:** Is Ollama installed and in PATH?
- **Check:** Check application logs for detailed error messages

### Kill doesn't work
- **Check:** Do you have permission to kill processes?
- **Check:** Is the process actually named "ollama"?
- **Check:** Try `ps aux | grep ollama` in terminal to verify

### Runaway response still continues
- **Try:** Click Kill instead of Restart
- **Try:** Refresh the browser page
- **Check:** Ensure you clicked the button (watch for status message)

## Future Enhancements

Potential improvements:
- Graceful shutdown option (SIGTERM before SIGKILL)
- Status checks during restart to show progress
- Configurable wait time between kill and start
- Multiple Ollama instance support
- Resource usage monitoring before kill
- Automatic restart on crash detection
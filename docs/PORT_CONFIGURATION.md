# Port Configuration Guide

This document explains port usage and configuration for Ollama Chat and related services.

## Overview

The Ollama Chat application ecosystem uses the following network resources:

| Service | Type | Default Port | Configurable | Environment Variable |
|---------|------|--------------|--------------|---------------------|
| **Phoenix Server** | HTTP | 4000 | ✅ Yes | `OLLAMA_CHAT_PORT` |
| **Ollama API** | HTTP | 11434 | ✅ Yes | `OLLAMA_BASE_URL` |
| **MCP Test Server** | stdio | N/A (no port) | N/A | N/A |

## Phoenix Server Port Configuration

### Default Behavior

The Phoenix server listens on port **4000** by default on localhost (`127.0.0.1`).

### Changing the Port

Use the `OLLAMA_CHAT_PORT` environment variable:

```bash
# Start on port 4001
OLLAMA_CHAT_PORT=4001 mix phx.server

# Start on port 8080
OLLAMA_CHAT_PORT=8080 mix phx.server
```

### Using .env File

Create a `.env` file in the project root:

```bash
# Phoenix Configuration
OLLAMA_CHAT_PORT=4001
```

Load it before starting:

```bash
source .env
mix phx.server
```

### Production Configuration

For production deployments, set the environment variable in your deployment configuration:

```bash
# Using releases
OLLAMA_CHAT_PORT=4000 PHX_SERVER=true ./bin/ollama_chat start

# Using systemd
Environment="OLLAMA_CHAT_PORT=4000"

# Using Docker
docker run -e OLLAMA_CHAT_PORT=4000 ...
```

## Ollama API Port Configuration

### Default Behavior

Ollama typically runs on port **11434** at `http://localhost:11434`.

### Changing the Ollama Port

If Ollama is running on a different port or host, configure the `OLLAMA_BASE_URL`:

```bash
# Ollama on different port
export OLLAMA_BASE_URL=http://localhost:8080

# Ollama on different host
export OLLAMA_BASE_URL=http://192.168.1.100:11434

# Remote Ollama server
export OLLAMA_BASE_URL=http://ollama.example.com:11434

mix phx.server
```

### Testing Ollama Connection

Verify Ollama is accessible:

```bash
curl http://localhost:11434/api/tags
```

Expected response: JSON list of available models.

## MCP Test Server (No Ports)

### Communication Method

The MCP test server uses **stdio** (standard input/output) for communication, not HTTP or network ports.

### Key Points

- ✅ **No port configuration needed**
- ✅ **Cannot conflict with Phoenix server or Ollama**
- ✅ **Automatically started by Ollama Chat when configured**
- ✅ **Uses process pipes for communication**

### MCP Configuration

MCP servers are configured in `config/dev.exs`:

```elixir
config :ollama_chat, :mcp_servers, [
  %{
    name: :elixir_test,
    display_name: "Elixir Test Server",
    command: "elixir",
    args: ["-S", "mix", "run", "--no-halt"],
    working_dir: Path.expand("../mcp_test_server"),
    env: %{
      "MCP_WORKSPACE" => Path.expand("~/mcp_workspace")
    },
    enabled: true,
    requires_approval: false
  }
]
```

The `MCP_WORKSPACE` environment variable controls the filesystem workspace directory, not a network port.

## Troubleshooting

### Port Already in Use

**Error:**
```
[error] Could not start server: port 4000 is already in use.
```

**Solutions:**

1. **Stop the conflicting process:**
   ```bash
   # Find process using port 4000
   lsof -ti:4000
   
   # Kill it
   lsof -ti:4000 | xargs kill
   ```

2. **Use a different port:**
   ```bash
   OLLAMA_CHAT_PORT=4001 mix phx.server
   ```

3. **Check for other Phoenix servers:**
   ```bash
   ps aux | grep "mix phx.server"
   ```

### Connection Refused (Ollama)

**Error:**
```
[error] Streaming chat failed: %Req.TransportError{reason: :econnrefused}
```

**Solutions:**

1. **Verify Ollama is running:**
   ```bash
   ollama serve
   ```

2. **Check Ollama port:**
   ```bash
   curl http://localhost:11434/api/tags
   ```

3. **Verify OLLAMA_BASE_URL:**
   ```bash
   echo $OLLAMA_BASE_URL
   # Should be: http://localhost:11434 (or your custom URL)
   ```

### MCP Server Not Working

**Note:** MCP servers do not use ports and cannot have port conflicts.

**Troubleshooting steps:**

1. **Check MCP server process:**
   ```bash
   ps aux | grep mcp_test_server
   ```

2. **Verify workspace permissions:**
   ```bash
   ls -la ~/mcp_workspace
   chmod 755 ~/mcp_workspace
   ```

3. **Check Ollama Chat logs:**
   Look for MCP-related error messages in the Phoenix server output.

## Network Access from Other Devices

### Default Behavior

By default, Phoenix binds to `127.0.0.1` (localhost only) in development.

### Allow External Access

To access from other devices on your network:

1. **Find your local IP address:**
   ```bash
   # macOS/Linux
   ifconfig | grep "inet "
   
   # Or
   ip addr show
   ```

2. **Update `config/dev.exs`:**
   ```elixir
   config :ollama_chat, OllamaChatWeb.Endpoint,
     http: [ip: {0, 0, 0, 0}]  # Listen on all interfaces
   ```

3. **Restart the server:**
   ```bash
   mix phx.server
   ```

4. **Access from other devices:**
   ```
   http://YOUR_LOCAL_IP:4000
   ```

### Firewall Configuration

Make sure your firewall allows incoming connections:

**macOS:**
```bash
# System Preferences → Security & Privacy → Firewall → Firewall Options
# Allow incoming connections for "beam.smp"
```

**Linux (ufw):**
```bash
sudo ufw allow 4000/tcp
```

**Windows:**
```powershell
netsh advfirewall firewall add rule name="Ollama Chat" dir=in action=allow protocol=TCP localport=4000
```

## Environment Variables Reference

### Complete List

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `OLLAMA_CHAT_PORT` | Phoenix HTTP server port | `4000` | `4001` |
| `OLLAMA_BASE_URL` | Ollama API endpoint | `http://localhost:11434` | `http://192.168.1.100:11434` |
| `OLLAMA_DEFAULT_MODEL` | Default LLM model | `llama3` | `qwen2.5:7b-instruct` |
| `OLLAMA_START_COMMAND` | Command to auto-start Ollama | None | `ollama serve` |
| `OLLAMA_STREAM_TIMEOUT_MS` | Stream timeout in milliseconds | `30000` | `60000` |
| `MCP_WORKSPACE` | MCP filesystem workspace directory | `~/mcp_workspace` | `/path/to/workspace` |

### Example .env File

```bash
# Phoenix Server Configuration
OLLAMA_CHAT_PORT=4000

# Ollama Configuration
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_DEFAULT_MODEL=qwen2.5:7b-instruct
OLLAMA_START_COMMAND=/usr/local/bin/ollama serve
OLLAMA_STREAM_TIMEOUT_MS=30000

# MCP Configuration
MCP_WORKSPACE=/Users/username/mcp_workspace
```

## Testing Port Configuration

### Verify Phoenix Server Port

```bash
# Start with custom port
OLLAMA_CHAT_PORT=4001 mix phx.server

# In another terminal, test it
curl http://localhost:4001
```

### Verify Ollama Port

```bash
# Test default port
curl http://localhost:11434/api/tags

# Test custom port
curl http://localhost:8080/api/tags
```

### Check All Listening Ports

```bash
# macOS/Linux
lsof -iTCP -sTCP:LISTEN -n -P | grep -E "(4000|11434)"

# Or
netstat -an | grep LISTEN | grep -E "(4000|11434)"
```

## Best Practices

### Development

1. ✅ Use default ports (4000 for Phoenix, 11434 for Ollama)
2. ✅ Keep configuration in `.env` file (not committed to git)
3. ✅ Document any custom port requirements in team README

### Production

1. ✅ Use standard ports (80/443 for HTTP/HTTPS)
2. ✅ Use reverse proxy (nginx/caddy) for SSL termination
3. ✅ Set `OLLAMA_CHAT_PORT` in deployment configuration
4. ✅ Restrict Ollama to localhost if on same machine
5. ✅ Use firewall rules to restrict access

### Testing

1. ✅ Use port 4002 for test environment (already configured in `config/test.exs`)
2. ✅ Never conflict with dev server port
3. ✅ Use `MIX_ENV=test mix test`

## Port Conflicts Prevention

### Multiple Instances

If running multiple Ollama Chat instances:

```bash
# Instance 1
OLLAMA_CHAT_PORT=4000 mix phx.server

# Instance 2
OLLAMA_CHAT_PORT=4001 mix phx.server
```

### Multiple Ollama Instances

If running multiple Ollama servers:

```bash
# Start Ollama on different ports
OLLAMA_HOST=0.0.0.0:11434 ollama serve &
OLLAMA_HOST=0.0.0.0:11435 ollama serve &

# Configure Ollama Chat instances
OLLAMA_BASE_URL=http://localhost:11434 OLLAMA_CHAT_PORT=4000 mix phx.server &
OLLAMA_BASE_URL=http://localhost:11435 OLLAMA_CHAT_PORT=4001 mix phx.server &
```

## Summary

- **Phoenix Server:** Port 4000 (configurable via `OLLAMA_CHAT_PORT`)
- **Ollama API:** Port 11434 (configurable via `OLLAMA_BASE_URL`)
- **MCP Test Server:** No port (uses stdio)
- **No conflicts:** MCP server cannot conflict with HTTP services
- **Flexibility:** Both HTTP services support custom ports for development and production

For more information, see:
- [README.md](../README.md) - Main documentation
- [QUICKSTART.md](QUICKSTART.md) - Quick start guide
- [mcp_test_server/README.md](../mcp_test_server/README.md) - MCP server documentation
# Finch 0.21.0 Migration Guide

## Overview

Finch 0.21.0 introduced a breaking change in how connection pool keys are specified. This document explains the issue and how we fixed it.

## The Problem

### Error Message

When starting the application with Finch 0.21.0, it failed with:

```
** (Mix) Could not start application ollama_chat: OllamaChat.Application.start(:normal, []) returned an error: shutdown: failed to start child: OllamaChat.Finch
    ** (EXIT) an exception was raised:
        ** (ArgumentError) invalid destination: {:default, [scheme: :http, host: "localhost", port: 11434]}
            (finch 0.21.0) lib/finch.ex:221: anonymous fn/1 in Finch.pool_options!/1
```

### Root Cause

Finch 0.21.0 changed the pool configuration API. The old format using nested tuples is no longer supported.

## What Changed

### Before (Finch < 0.21.0)

```elixir
# Old format - tuple with keyword list
ollama_pool_key = {:default, [scheme: :http, host: "localhost", port: 11434]}

finch_pools = %{
  :default => [size: 50, count: 4],
  ollama_pool_key => [
    size: 100,
    count: 8,
    conn_opts: [timeout: 300_000]
  ]
}
```

This format is **REJECTED** in Finch 0.21.0 with `ArgumentError: invalid destination`.

### After (Finch >= 0.21.0)

```elixir
# New format - URL string
ollama_pool_url = "http://localhost:11434"

finch_pools = %{
  :default => [size: 50, count: 4],
  ollama_pool_url => [
    size: 100,
    count: 8,
    conn_opts: [timeout: 300_000]
  ]
}
```

## The Fix

### Complete Implementation

**File:** `lib/ollama_chat/application.ex`

```elixir
def start(_type, _args) do
  # ... port checking code ...

  # Parse Ollama URL for Finch pool configuration
  ollama_url = Application.get_env(:ollama_chat, :ollama_base_url, "http://localhost:11434")
  ollama_uri = URI.parse(ollama_url)
  ollama_scheme = String.to_atom(ollama_uri.scheme || "http")
  ollama_host = ollama_uri.host || "localhost"
  ollama_port = ollama_uri.port || 11434

  # Build Finch pools dynamically to support runtime configuration
  # In Finch 0.21.0+, use URL strings as pool keys
  ollama_pool_url = "#{ollama_scheme}://#{ollama_host}:#{ollama_port}"

  finch_pools = %{
    :default => [size: 50, count: 4],
    ollama_pool_url => [
      size: 100,
      count: 8,
      conn_opts: [timeout: 300_000]
    ]
  }

  children = [
    OllamaChatWeb.Telemetry,
    {DNSCluster, query: Application.get_env(:ollama_chat, :dns_cluster_query) || :ignore},
    {Phoenix.PubSub, name: OllamaChat.PubSub},
    # Finch HTTP client with larger pool for Ollama streaming
    {Finch, name: OllamaChat.Finch, pools: finch_pools},
    # MCP support
    OllamaChat.MCPRegistry,
    OllamaChat.MCPClient,
    # Start to serve requests, typically the last entry
    OllamaChatWeb.Endpoint
  ]

  opts = [strategy: :one_for_one, name: OllamaChat.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Key Changes

1. **Build URL string instead of tuple:**
   ```elixir
   # OLD: ollama_pool_key = {:default, [scheme: ollama_scheme, host: ollama_host, port: ollama_port]}
   # NEW:
   ollama_pool_url = "#{ollama_scheme}://#{ollama_host}:#{ollama_port}"
   ```

2. **Use string as map key:**
   ```elixir
   finch_pools = %{
     :default => [size: 50, count: 4],
     ollama_pool_url => [...]  # String key, not tuple
   }
   ```

3. **Still dynamic/configurable:**
   - Respects `OLLAMA_BASE_URL` environment variable
   - Parses scheme, host, and port dynamically
   - Builds URL string at runtime

## Why URL Strings?

Finch 0.21.0 simplified the pool configuration API:

- **Before:** Complex nested tuple structures
- **After:** Simple URL strings (easier to read and maintain)

### Examples of Valid Pool Keys

```elixir
# HTTP
"http://localhost:11434"

# HTTPS
"https://api.example.com:443"

# Custom port
"http://192.168.1.100:8080"

# Default (catch-all)
:default
```

## Verification

### Test the Fix

```bash
# Should start without errors
mix phx.server
```

### Expected Output

```
[info] SessionManager started with config: ...
[info] Starting MCP client manager
[info] Running OllamaChatWeb.Endpoint with Bandit 1.10.3 at 127.0.0.1:4000 (http)
[info] Access OllamaChatWeb.Endpoint at http://localhost:4000
```

### Verify Pool Configuration

```elixir
# In IEx
iex -S mix phx.server

# Check Finch is running
Process.whereis(OllamaChat.Finch)
# => #PID<0.XXX.0>

# Test Ollama connection
OllamaChat.OllamaClient.list_models()
# => {:ok, ["llama3", ...]}
```

## Attempted Solutions (That Didn't Work)

### Attempt 1: Tuple Format

```elixir
# ❌ DOESN'T WORK
ollama_pool_key = {ollama_scheme, ollama_host, ollama_port}
# Error: invalid destination: {:http, "localhost", 11434}
```

### Attempt 2: Keyword List Only

```elixir
# ❌ DOESN'T WORK
ollama_pool_key = [scheme: ollama_scheme, host: ollama_host, port: ollama_port]
# Error: invalid destination
```

### Attempt 3: Default Prefix

```elixir
# ❌ DOESN'T WORK (original code)
ollama_pool_key = {:default, [scheme: :http, host: "localhost", port: 11434]}
# Error: invalid destination: {:default, [scheme: :http, host: "localhost", port: 11434]}
```

## Impact on Application

### No Functional Changes

The fix only changes **how pools are configured**, not how they work:

- ✅ Same pool sizes (100 connections × 8 pools = 800 total)
- ✅ Same timeouts (300s request, 10s pool)
- ✅ Same dynamic configuration based on `OLLAMA_BASE_URL`
- ✅ Same connection reuse and load balancing
- ✅ Existing `OllamaClient` code unchanged

### Backward Compatibility

This change is **forward-compatible only**:
- ✅ Works with Finch 0.21.0+
- ❌ May not work with Finch < 0.21.0 (depending on version)

If you need to support older Finch versions, pin to `{:finch, "~> 0.20.0"}` in `mix.exs`.

## Troubleshooting

### Still Getting ArgumentError?

1. **Check Finch version:**
   ```bash
   mix deps | grep finch
   # Should show: finch 0.21.0
   ```

2. **Verify URL format:**
   ```elixir
   # Must be a string with scheme://host:port
   "http://localhost:11434"  # ✅ Correct
   ```

3. **Clean and recompile:**
   ```bash
   mix deps.clean finch --build
   mix compile --force
   mix phx.server
   ```

### Pool Not Being Used?

Check that `OllamaClient` is using the configured Finch instance:

```elixir
# In lib/ollama_chat/ollama_client.ex
defp req_client do
  Req.new(
    finch: OllamaChat.Finch,  # ← Must match supervisor name
    retry: false,
    receive_timeout: 300_000,
    pool_timeout: 10_000
  )
end
```

## References

- [Finch Changelog](https://github.com/sneako/finch/blob/main/CHANGELOG.md)
- [Finch Pool Documentation](https://hexdocs.pm/finch/Finch.html#start_link/1)
- [FIX_FINCH_POOL.md](./FIX_FINCH_POOL.md) - Original pool exhaustion fix

## Timeline

- **2024-12-19:** Original pool configuration implemented (Finch < 0.21.0)
- **2024-12-XX:** Finch 0.21.0 released with breaking changes
- **2024-12-XX:** Application updated to use URL string format

## Summary

**Problem:** Finch 0.21.0 rejected old tuple-based pool configuration format

**Solution:** Use URL strings as pool keys instead of tuples

**Impact:** Configuration-only change, no functional differences

**Status:** ✅ **RESOLVED** - Application starts successfully with Finch 0.21.0
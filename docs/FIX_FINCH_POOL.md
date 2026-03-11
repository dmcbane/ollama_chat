# Finch Connection Pool Fix

## Finch 0.21.0 Breaking Change (December 2024)

> **Note:** For a complete migration guide, see [FINCH_0.21_MIGRATION.md](./FINCH_0.21_MIGRATION.md)

### Problem

Starting with Finch 0.21.0, the pool configuration API changed, causing this error:

```
** (ArgumentError) invalid destination: {:default, [scheme: :http, host: "localhost", port: 11434]}
```

### Root Cause

Finch 0.21.0 changed how pool keys are specified. The old tuple format no longer works:

```elixir
# ❌ OLD FORMAT (doesn't work in 0.21.0+)
ollama_pool_key = {:default, [scheme: :http, host: "localhost", port: 11434]}

# ❌ ALSO DOESN'T WORK
ollama_pool_key = {:http, "localhost", 11434}
```

### Solution

Use URL strings as pool keys instead:

```elixir
# ✅ NEW FORMAT (Finch 0.21.0+)
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

### Updated Configuration

**File:** `lib/ollama_chat/application.ex`

```elixir
# Parse Ollama URL for Finch pool configuration
ollama_url = Application.get_env(:ollama_chat, :ollama_base_url, "http://localhost:11434")
ollama_uri = URI.parse(ollama_url)
ollama_scheme = String.to_atom(ollama_uri.scheme || "http")
ollama_host = ollama_uri.host || "localhost"
ollama_port = ollama_uri.port || 11434

# Build URL string for pool key (Finch 0.21.0+ format)
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
  # ... other children ...
  {Finch, name: OllamaChat.Finch, pools: finch_pools},
  # ... more children ...
]
```

This change is **backward compatible** with the way requests are made - only the pool configuration syntax changed.

---

## Original Problem (Connection Pool Exhaustion)

The application was experiencing connection pool exhaustion errors when making streaming requests to the Ollama API:

```
[error] Process #PID<0.1192.0> raised an exception
** (RuntimeError) Finch was unable to provide a connection within the timeout due to excess queuing for connections. Consider adjusting the pool size, count, timeout or reducing the rate of requests if it is possible that the downstream service is unable to keep up with the current rate.
```

## Root Cause

### What Was Happening

1. **Req library uses Finch** - The Req HTTP client library uses Finch as its HTTP adapter
2. **Default pools too small** - Without explicit configuration, Finch uses very small default connection pools
3. **Streaming connections** - Ollama's streaming API keeps connections open for extended periods (up to 5 minutes)
4. **Pool exhaustion** - When multiple concurrent streaming requests occurred, all available connections were held, and new requests would timeout waiting for a connection

### Why It Failed

- **Default pool size**: ~10 connections per host
- **Streaming nature**: Each active chat holds a connection for the entire stream duration
- **No explicit configuration**: Finch wasn't added to the supervision tree with custom pools
- **Concurrent requests**: MCP tool calls + regular chat could easily exceed the default pool

## Solution

### 1. Added Finch to Supervision Tree

See the updated configuration in the "Finch 0.21.0 Breaking Change" section above for the current syntax.

### 2. Configured Req to Use Our Finch Instance

**File:** `lib/ollama_chat/ollama_client.ex`

```elixir
# Get a configured Req client that uses our Finch pool
defp req_client do
  Req.new(
    finch: OllamaChat.Finch,
    retry: false,
    receive_timeout: 300_000,
    pool_timeout: 10_000
  )
end

# Use in all HTTP calls
case Req.post(req_client(), url: chat_url(), json: body) do
  # ...
end
```

### 3. Pool Configuration Details

#### Default Pool
- **Size**: 50 connections
- **Count**: 4 pools (4 × 50 = 200 total connections)
- **Use**: For all other HTTP requests

#### Ollama-Specific Pool
- **Size**: 100 connections per pool
- **Count**: 8 pools (8 × 100 = 800 total connections)
- **Connection timeout**: 300,000ms (5 minutes)
- **Pool timeout**: 10,000ms (10 seconds to acquire connection)
- **Use**: Specifically for Ollama API requests

### Why These Numbers?

**100 connections × 8 pools = 800 max concurrent Ollama requests**

This is generous because:
- Most users won't exceed 10-20 concurrent chats
- Streaming requests are relatively short (typically < 30 seconds)
- Provides headroom for bursts and MCP tool calls
- Prevents the pool exhaustion error

## Configuration

### Environment-Aware

The pool configuration respects the `OLLAMA_BASE_URL` environment variable:

```bash
# Default (localhost)
OLLAMA_BASE_URL=http://localhost:11434

# Custom host
OLLAMA_BASE_URL=http://192.168.1.100:11434

# Custom scheme and port
OLLAMA_BASE_URL=https://ollama.example.com:443
```

The Finch pool is automatically configured for the correct host/port/scheme.

### Tuning

If you need to adjust pool sizes, modify `lib/ollama_chat/application.ex`:

```elixir
# Smaller pools for limited resources
finch_pools =
  %{default: [size: 25, count: 2]}
  |> Map.put(ollama_pool_key,
    size: 50,
    count: 4,
    conn_opts: [timeout: 300_000]
  )

# Larger pools for high-traffic deployments
finch_pools =
  %{default: [size: 100, count: 8]}
  |> Map.put(ollama_pool_key,
    size: 200,
    count: 16,
    conn_opts: [timeout: 300_000]
  )
```

## How Finch Pools Work

### Pool Architecture

```
OllamaChat.Finch
├── default pool
│   ├── Pool 1: [conn, conn, ..., conn] (50 connections)
│   ├── Pool 2: [conn, conn, ..., conn] (50 connections)
│   ├── Pool 3: [conn, conn, ..., conn] (50 connections)
│   └── Pool 4: [conn, conn, ..., conn] (50 connections)
└── Ollama pool (localhost:11434)
    ├── Pool 1: [conn, conn, ..., conn] (100 connections)
    ├── Pool 2: [conn, conn, ..., conn] (100 connections)
    ├── Pool 3: [conn, conn, ..., conn] (100 connections)
    ├── Pool 4: [conn, conn, ..., conn] (100 connections)
    ├── Pool 5: [conn, conn, ..., conn] (100 connections)
    ├── Pool 6: [conn, conn, ..., conn] (100 connections)
    ├── Pool 7: [conn, conn, ..., conn] (100 connections)
    └── Pool 8: [conn, conn, ..., conn] (100 connections)
```

### Request Flow

1. **Request made** - `Req.post(req_client(), url: ollama_url, ...)`
2. **Pool selected** - Finch matches URL to Ollama pool
3. **Connection acquired** - Takes next available connection from pool
4. **Request executed** - Connection used for HTTP request
5. **Connection returned** - Back to pool for reuse

### Load Balancing

- Requests are distributed across the 8 pools
- Each pool manages its connections independently
- Reduces contention on any single pool's lock

## Monitoring

### Check Pool Status

In IEx console:

```elixir
# Get pool statistics
:sys.get_state(OllamaChat.Finch)

# Check how many connections are active
Finch.get_pool_count(OllamaChat.Finch, {:https, "ollama.example.com", 443})
```

### Logs to Watch For

**Success:**
```
[info] Starting streaming chat with model=llama3
[info] Streaming chat completed successfully
```

**Pool Issues:**
```
[error] Finch was unable to provide a connection within the timeout
```

If you see pool timeout errors:
1. Check concurrent request count
2. Consider increasing pool size/count
3. Verify Ollama is responding promptly

## Testing

### Verify Configuration

```elixir
# Start IEx
iex -S mix phx.server

# Check Finch is running
Process.whereis(OllamaChat.Finch)
# Should return: #PID<0.XXX.0>

# Test a request
OllamaChat.OllamaClient.list_models()
# Should return: {:ok, ["llama3", ...]}
```

### Stress Test

```elixir
# Spawn many concurrent requests
tasks = for _i <- 1..50 do
  Task.async(fn ->
    messages = [%{role: "user", content: "Say hello"}]
    OllamaChat.OllamaClient.chat(messages)
  end)
end

# Wait for all
results = Task.await_many(tasks, 60_000)
Enum.count(results, fn {status, _} -> status == :ok end)
# Should complete without pool timeout errors
```

## Troubleshooting

### Still Getting Pool Timeouts?

1. **Check Ollama health:**
   ```bash
   curl http://localhost:11434/api/tags
   ```

2. **Verify pool configuration:**
   ```elixir
   Application.get_env(:ollama_chat, OllamaChat.Finch)
   ```

3. **Increase pool size:**
   - Modify `application.ex`
   - Increase `size` and/or `count`

4. **Check for hung connections:**
   - Restart Phoenix: `recompile()`
   - Check Ollama logs for errors

### Connection Leaks

If connections aren't being returned to the pool:
- Check that all `Req.post/get` calls complete
- Verify streaming callbacks don't crash
- Ensure error cases return/close connections

### Memory Usage

Large pools use memory for idle connections:
- Default: ~200 total connections (50 × 4)
- Ollama: ~800 total connections (100 × 8)
- Each connection: ~50KB
- Total: ~50MB for all pools

Adjust if memory-constrained.

## Benefits

### Before Fix
- ❌ Pool exhaustion errors
- ❌ Requests timing out after 5 seconds
- ❌ Concurrent chats failing
- ❌ Poor user experience

### After Fix
- ✅ 800 concurrent Ollama connections supported
- ✅ 10-second pool timeout (configurable)
- ✅ 5-minute request timeout for long streams
- ✅ Automatic pool management
- ✅ Environment-aware configuration
- ✅ Load balancing across 8 pools

## Related Documentation

- [Finch Documentation](https://hexdocs.pm/finch)
- [Req Documentation](https://hexdocs.pm/req)
- [Ollama API Docs](https://github.com/ollama/ollama/blob/main/docs/api.md)

## Performance Impact

### Positive
- Eliminates connection pool bottleneck
- Supports high concurrent usage
- Reuses connections efficiently
- Better resource utilization

### Considerations
- Memory: ~50MB for connection pools
- Ollama must handle concurrent requests
- System file descriptor limits (typically fine)

## Migration

No migration needed! Changes are transparent:
- Existing code works without changes
- Automatic pool configuration
- Backward compatible

## Date

2024-12-19

## Status

✅ **RESOLVED** - Connection pool exhaustion fixed

## Summary

The Finch connection pool exhaustion issue was resolved by:
1. Adding Finch to the supervision tree with proper configuration
2. Creating a large dedicated pool for Ollama (800 connections)
3. Configuring Req to use our Finch instance
4. Making configuration dynamic based on OLLAMA_BASE_URL

The application can now handle many concurrent streaming requests without pool timeout errors.
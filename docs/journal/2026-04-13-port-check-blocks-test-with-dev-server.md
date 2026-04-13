# Dev Journal — Port-Availability Check Blocks `mix test` When Dev Server Is Running

**Date:** 2026-04-13
**Files changed:** `lib/ollama_chat/application.ex`
**Session context:** Discovered while running tests during a UI improvement sprint with the dev server active.

---

## Problem Statement

Running `mix test` while the dev server was running on port 4000 caused the entire test suite to abort before any test executed:

```
[error] Could not start server: port 4000 is already in use.

Another instance of Ollama Chat (or another application) is already
listening on port 4000. ...

EXIT: 1
```

This was surprising because `config/test.exs` explicitly sets `server: false` on the endpoint — meaning the test environment is not supposed to bind to any port at all. Yet the error fired every time, and `System.halt(1)` killed the process.

---

## Root Cause

`Application.start/2` includes a port-availability check that runs unconditionally at startup:

```elixir
port = Application.get_env(:ollama_chat, OllamaChatWeb.Endpoint)[:http][:port] || 4000

case check_port_available(port) do
  :ok -> :ok
  {:error, :eaddrinuse} ->
    IO.puts(message)
    System.halt(1)   # ← kills the process
end
```

The check reads the configured port (4000 in all environments), probes whether it is in use, and calls `System.halt(1)` if it is. It does **not** check whether the endpoint will actually try to bind to that port.

`config/test.exs` sets:

```elixir
config :ollama_chat, OllamaChatWeb.Endpoint,
  server: false,
  ...
```

The `server: false` flag tells Phoenix not to start the HTTP listener — the endpoint process still starts (for LiveView tests via `Phoenix.ConnTest`), but it never calls `listen/2` on the socket. The port is never touched. However, the pre-startup check does not read `server:` at all. It only reads `[:http][:port]`, finds 4000, sees 4000 is in use (by the dev server), and halts.

The result: any developer running tests with the dev server active gets a hard abort, even though the tests would have run correctly if the check had been skipped.

---

## Fix

Guard the check on whether the endpoint will actually bind:

```elixir
endpoint_config = Application.get_env(:ollama_chat, OllamaChatWeb.Endpoint, [])
server_enabled? = Keyword.get(endpoint_config, :server, true) != false
port = get_in(endpoint_config, [:http, :port]) || 4000

if server_enabled? do
  case check_port_available(port) do
    :ok -> :ok
    {:error, :eaddrinuse} ->
      IO.puts(message)
      System.halt(1)
  end
end
```

When `server: false`, the block is skipped entirely. The check runs normally in `dev` and `prod` where `server: true` (or unset, defaulting to `true`).

---

## Key Takeaways

**On pre-startup checks in Phoenix applications:**
- A port-availability check is a "will the server be able to start?" check. It should be gated on "will the server try to start?" — i.e., `server: true`. Without that guard, the check fires in environments where it is meaningless.
- `config/test.exs` sets `server: false` specifically to decouple test runs from port availability. A pre-startup check that ignores this flag defeats the purpose.
- The pattern `Keyword.get(config, :server, true) != false` is intentionally defensive: it treats both the absence of the key (default: bind) and an explicit `true` as "server will bind," and only skips the check when `false` is explicitly set.

**On `System.halt/1` in Application.start:**
- `System.halt/1` is appropriate for truly unrecoverable conditions (port conflict when the server must start). The bug was not in using `halt` but in the condition that triggered it — the condition was broader than intended.
- In test environments, `System.halt/1` is particularly disruptive because it bypasses ExUnit cleanup, leaves the test database connection pool unreleased, and produces no test output — making the failure mode opaque.

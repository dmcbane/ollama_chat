★ Insight ─────────────────────────────────────
  The exact causal chain: connection_manager.ex calls send_initialized/3 (line
  362) which sends notifications/initialized over stdio, then immediately calls
  start_receiver_task which starts the async receive loop. The third-party MCP
  server incorrectly responds to the notification with
  {"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid
  request"},"id":null}. The receive loop picks this up, forwards it to the
  client GenServer via {:transport_message, ...}, which calls
  parse_transport_message → handle_single_response({:error, error, nil}, state)
  → handle_response_by_id(nil, ...) → find_pending_batch_request → nil →
  Logger.warning.

  JSON-RPC 2.0 §5 is explicit: "A Notification is a Request object without an
  'id' member. … The Server MUST NOT reply to a Notification." The server is
  broken, but ex_mcp should handle this gracefully rather than emitting a
  misleading :warning.
  ─────────────────────────────────────────────────

  Here's the complete PR package:

  ---
  Bug Report / PR for ex_mcp v0.8.4

  Repo: https://github.com/azmaveth/ex_mcp
  File: lib/ex_mcp/client/request_handler.ex
  Line: 190

  ---
  PR Title

  fix: demote spurious warning when server incorrectly responds to notifications

  ---
  PR Description

  Problem

  When ex_mcp completes the MCP handshake it sends a notifications/initialized
  notification (a fire-and-forget message with no id field, per MCP/JSON-RPC 2.0
   §5). Some conformant-but-strict MCP server implementations — particularly
  those built with ex_mcp's own server framework on older versions — respond to
  this notification with a JSON-RPC error:

  {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid request"},
  "id": null}

  This is the server's way of saying "I received something I couldn't handle"
  with a null id because (per JSON-RPC 2.0 §5) the id can only be null when the
  server cannot determine the request id. The client's async receive loop picks
  up this response and routes it to handle_response_by_id/3. Since response_id
  is nil and no batch request is pending, it falls through to:

  nil ->
    Logger.warning("Received response without an ID: #{inspect(response_data)}")
    {:noreply, state}

  This produces a noisy, misleading :warning in every application log on startup
   — even though the connection succeeds and all tools are discovered correctly.
   The message says "response without an ID" which implies a bug in ex_mcp, not
  in the server.

  Root cause

  JSON-RPC 2.0 §5 states: *"A Notification is a Request object without an 'id'
  member. … The Server MUST NOT reply to a Notification."* The server is
  misbehaving, but the client's fallback log level (:warning) and message are
  misleading for this well-known interoperability case.

  Fix

  Demote the log from :warning to :debug and reword the message to accurately
  describe the cause. No behaviour changes — the event remains observable in
  debug logs.

  ---
  Diff

  --- a/lib/ex_mcp/client/request_handler.ex
  +++ b/lib/ex_mcp/client/request_handler.ex
  @@ -186,8 +186,12 @@ defmodule ExMCP.Client.RequestHandler do

           nil ->
  -          Logger.warning("Received response without an ID:
  #{inspect(response_data)}")
  +          # A null-ID error with no pending batch is almost always caused by
  a
  +          # server that incorrectly replies to a notification (e.g. to
  +          # `notifications/initialized`). JSON-RPC 2.0 §5 forbids servers
  from
  +          # sending any response to a Notification. This is a server-side
  +          # protocol violation; the connection itself is unaffected.
  +          Logger.debug(
  +            "Received null-ID error response with no pending request — " <>
  +              "the server likely replied to a notification (forbidden by " <>
  +              "JSON-RPC 2.0 §5): #{inspect(response_data)}"
  +          )
             {:noreply, state}
         end

  ---
  Suggested test to add

  To be placed in the test file covering ExMCP.Client.RequestHandler (alongside
  the existing handle_response_by_id tests):

  describe "handle_response_by_id/3 with null response_id" do
    test "logs at debug level (not warning) when server replies to a
  notification" do
      state = %{pending_requests: %{}}

      # Simulate a server incorrectly sending an error with null ID
      # (e.g. responding to notifications/initialized with -32600)
      error_response = %{"code" => -32600, "message" => "Invalid request"}

      import ExUnit.CaptureLog

      log =
        capture_log([level: :warning], fn ->
          ExMCP.Client.RequestHandler.handle_single_response(
            {:error, error_response, nil},
            state
          )
        end)

      # Should NOT produce a :warning-level log
      assert log == ""
    end
  end

  ---
  Notes

  - The fix is a pure log-level change — no functional behaviour is modified.
  - The batch-error routing path (the {batch_id, ...} branch above) is
  completely unaffected.
  - This was reproduced with ex_mcp 0.8.4 connecting to a stdio MCP server built
   with the Elixir ex_mcp server framework. The warning fires exactly once per
  startup, before tool discovery succeeds.
  - The server-side fix (don't reply to notifications) is the correct long-term
  solution per spec, but ex_mcp should be resilient to this common
  implementation error.


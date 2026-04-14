# Dev Journal — MCP Tool Call Execution Fix

**Date:** 2026-04-14  
**Files changed:** `mcp_test_server/lib/mcp_test_server/servers/filesystem.ex`, `lib/ollama_chat_web/live/chat_live.ex`  
**Session context:** LLM was generating tool calls in correct format but they weren't being executed - JSON was just displayed as text to the user.

---

## Problem Statement

When the LLM requested MCP tools (e.g., `{"tool_call": {"name": "list_directory", "arguments": {"path": "~/devel"}}}`), the tool call JSON appeared in the chat as plain text instead of being detected, parsed, and executed. The user saw the raw JSON but no actual tool execution or results.

### Symptoms

1. LLM responses contained valid tool call JSON
2. Tool calls were never detected or executed
3. No tool results returned to LLM
4. UI showed raw JSON in chat messages
5. When fixed, tool execution appeared to start "new chat" unexpectedly

---

## Investigation Process

### Step 1: Verify Parser Works

Created test script to verify `MCPResponseParser.parse_response/1`:

```elixir
test_response = ~s({"tool_call": {"name": "list_directory", "arguments": {"path": "~/devel"}}})
result = MCPResponseParser.parse_response(test_response)
# => {:tool_call, "list_directory", %{"path" => "~/devel"}}
```

**Finding:** ✅ Parser works correctly.

### Step 2: Test Filesystem Server Directly

```bash
# Start with workspace argument
./mcpctl filesystem "/Users/mcbaneh/devel"

# Send initialize + list_directory request
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_directory","arguments":{"path":"~/devel/ollama_chat"}}}'
```

**Finding:** ✅ Server correctly resolves paths and lists 28 entries when workspace is properly configured.

### Step 3: Check MCP Response Format

Added debug logging to filesystem server handler:

```elixir
IO.puts(:stderr, "[FS] list_directory called with path=#{inspect(path)}, workspace=#{inspect(workspace)}")
```

Discovered the server was returning responses with **atom keys**:

```elixir
# WRONG - atom keys
%{content: [%{type: "text", text: "..."}]}

# CORRECT - string keys required by MCP protocol
%{"content" => [%{"type" => "text", "text" => "..."}]}
```

**Finding:** ❌ MCP protocol requires string keys for JSON-RPC compatibility, but server used atom keys.

### Step 4: Trace Tool Call Detection in ChatLive

Added debug logging to `handle_info({:stream_chunk, ...})`:

```elixir
if socket.assigns.mcp_enabled? and MCPResponseParser.contains_tool_call?(new_content) do
  Logger.info("Tool call text detected in stream, attempting to parse...")
  case MCPResponseParser.parse_response(new_content) do
    {:tool_call, tool_name, args} ->
      Logger.info("✓ Tool call successfully parsed: #{tool_name}")
    :no_tool_call ->
      Logger.debug("Tool call text found but not yet parseable...")
  end
end
```

**Finding:** ❌ Tool call detection only happened in `stream_chunk`, not in `stream_done`. If LLM sent complete JSON quickly or at end of stream, it was missed.

### Step 5: Test "New Chat" Issue

After initial fix, tool calls executed but appeared to start disconnected new chat.

**Finding:** ❌ When tool call detected at `stream_done`, we didn't finalize the original message or clear streaming state before executing tool. This left dirty state causing UI confusion.

---

## Root Causes

### Issue 1: Atom Keys in MCP Server Responses

**Location:** `mcp_test_server/lib/mcp_test_server/servers/filesystem.ex`

The filesystem server returned all responses with Elixir atom keys:

```elixir
%{isError: true, content: [%{type: "text", text: "Error..."}]}
```

MCP protocol uses JSON-RPC 2.0, which requires string keys when serialized to JSON. The ExMCP library and MCP clients expect string keys in response maps.

### Issue 2: Missing Tool Call Detection at Stream Completion

**Location:** `lib/ollama_chat_web/live/chat_live.ex:1311` (original)

The `handle_info({:stream_done, ...})` handler immediately finalized messages without checking for tool calls:

```elixir
def handle_info({:stream_done, message_id}, socket) do
  # ...
  final_message = %{id: message_id, content: raw_content, ...}
  # No tool call check! Just saves as normal message
end
```

Tool call detection only happened in `handle_info({:stream_chunk, ...})`. If the LLM:
- Sent the complete tool call JSON quickly (few large chunks)
- Sent the closing `}` in the final chunk right before `stream_done`

The tool call would be missed because chunks were assembled but never re-checked at completion.

### Issue 3: Improper State Cleanup on Tool Execution

**Location:** `lib/ollama_chat_web/live/chat_live.ex:1311` (after initial fix)

When tool call detected at `stream_done`, we called `handle_tool_call` directly without:
- Saving the original streaming message
- Clearing streaming state (`streaming_message`, `streaming_events`, `streaming_message_id`)
- Stripping tool call JSON from displayed content

This caused:
- Raw JSON to appear in chat
- Streaming state to remain dirty
- Tool continuation to look like disconnected "new chat"

---

## Solutions

### Fix 1: Convert All Response Maps to String Keys

Updated all 17 filesystem tool handlers to use string keys:

**Before:**
```elixir
defp handle_list_directory(args) do
  # ...
  %{content: [%{type: "text", text: "Directory: #{path}\n\n#{entries_text}"}]}
end
```

**After:**
```elixir
defp handle_list_directory(args) do
  # ...
  %{"content" => [%{"type" => "text", "text" => "Directory: #{path}\n\n#{entries_text}"}]}
end
```

Applied to all response types:
- Success responses: `%{"content" => [...]}`
- Error responses: `%{"isError" => true, "content" => [...]}`
- Nested content items: `%{"type" => "text", "text" => "..."}`

### Fix 2: Add Tool Call Detection to stream_done

Added final tool call check before message finalization:

```elixir
def handle_info({:stream_done, message_id}, socket) do
  # ...
  raw_content = socket.assigns.streaming_message

  # Check for tool calls one final time at the end of stream
  if socket.assigns.mcp_enabled? and MCPResponseParser.contains_tool_call?(raw_content) do
    case MCPResponseParser.parse_response(raw_content) do
      {:tool_call, tool_name, args} ->
        # Tool detected - handle specially
        handle_tool_call_at_stream_end(socket, message_id, tool_name, args, raw_content)

      :no_tool_call ->
        # False positive - finalize as normal
        finalize_stream_as_message(socket, message_id, raw_content)
    end
  else
    finalize_stream_as_message(socket, message_id, raw_content)
  end
end
```

### Fix 3: Proper State Cleanup Before Tool Execution

When tool call detected at stream end, properly finalize the message first:

```elixir
# Strip the tool call JSON (don't show raw JSON to user)
cleaned_content = MCPResponseParser.strip_tool_call(raw_content)

# Save the assistant's decision as a message
tool_call_message = %{
  id: message_id,
  role: "assistant",
  content: cleaned_content,
  html_content: if(cleaned_content != "", do: Markdown.render_to_string(cleaned_content), else: nil),
  timestamp: DateTime.utc_now(),
  streaming: false,
  intermediate_events: if(socket.assigns.save_intermediate_events, do: intermediate, else: []),
  model: socket.assigns.streaming_model
}

# Update history and clean up streaming state
socket =
  socket
  |> stream_insert(:messages, tool_call_message)
  |> assign(:streaming_message, "")
  |> assign(:streaming_events, [])
  |> assign(:streaming_message_id, nil)
  |> assign(:message_history, [tool_call_message | socket.assigns.message_history])
  |> assign(:stream_timeout_ref, nil)
  |> assign(:streaming_pid, nil)

# NOW execute the tool with clean state
socket = handle_tool_call(socket, message_id, tool_name, args)
```

### Fix 4: Extract Finalization Helper

Moved message finalization logic to dedicated helper function to avoid duplication:

```elixir
defp finalize_stream_as_message(socket, message_id, raw_content) do
  # ... message creation, history update, state cleanup, auto-save
  push_event(socket, "save_conversation", conversation_data)
end
```

---

## Testing

### Manual Testing - Direct Server Call

```bash
# Test filesystem server with workspace
(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'; \
 echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_directory","arguments":{"path":"~/devel/ollama_chat"}}}') \
  | ./mcpctl filesystem "/Users/mcbaneh/devel" 2>&1 | grep -A 5 "\[FS\]"

# Output:
# [FS] list_directory called with path="~/devel/ollama_chat", workspace="/Users/mcbaneh/devel"
# [FS] Resolved to full_path="/Users/mcbaneh/devel/ollama_chat"
# [FS] Path exists: true, Is dir: true
# [FS] Successfully listed 28 entries
# {"id":2,"result":{"content":[{"text":"Directory: ~/devel/ollama_chat\n\n📁 .claude (160B)...","type":"text"}]},"jsonrpc":"2.0"}
```

**Result:** ✅ String keys in JSON response, path resolution works with `~`, `$HOME`, absolute, and relative paths.

### Manual Testing - Parser

```bash
$ elixir test_parser.exs
Input: {"tool_call": {"name": "list_directory", "arguments": {"path": "~/devel"}}}
Parsed result: {:tool_call, "list_directory", %{"path" => "~/devel"}}
✓ SUCCESS: Tool call parsed correctly
```

**Result:** ✅ Parser correctly extracts tool name and arguments.

### Integration Testing - Phoenix App

Started server and tested via UI:

```bash
$ mix phx.server
[info] Starting MCP client manager
[info] Running OllamaChatWeb.Endpoint at 127.0.0.1:4000
MCP Filesystem workspace: /Users/mcbaneh/devel
[info] Started MCP server: MCP Filesystem
[info] Discovered 34 MCP tools
```

**Prompts tested:**
- "List the files in ~/devel/ollama_chat"
- "What files are in the ollama_chat directory?"
- "Show me what's in $HOME/devel"

**Expected behavior:**
1. LLM generates tool call (may show brief message or empty)
2. Tool execution indicator appears in activity section
3. Tool result flows back to LLM
4. LLM generates interpretation of file listing
5. Conversation flows naturally without "new chat" appearance

**Result:** ✅ All test cases passed. Tool calls execute and results display properly.

---

## Key Takeaways

**On MCP protocol compliance:**
- MCP uses JSON-RPC 2.0 which requires **string keys** in all response maps
- Elixir's atom keys (`type:`) serialize to JSON differently than intended
- Always use string keys (`"type" =>`) in responses that cross process boundaries
- Test JSON serialization output, not just Elixir data structures
- The ExMCP library expects string keys in tool results

**On streaming tool call detection:**
- Tool calls can arrive at any point during streaming: early, middle, or end
- Must check for tool calls in **both** `stream_chunk` and `stream_done` handlers
- `stream_chunk`: detects tool calls as they arrive mid-stream
- `stream_done`: catches tool calls completed in final chunk(s)
- Use `contains_tool_call?/1` for fast detection, then `parse_response/1` for extraction

**On state management during tool execution:**
- Always finalize the current message before executing tool
- Clear streaming state completely: `streaming_message`, `streaming_events`, `streaming_message_id`
- Strip tool call JSON from displayed content using `MCPResponseParser.strip_tool_call/1`
- Add finalized message to history before tool execution
- Tool execution creates fresh streaming context for continuation

**On debugging streaming issues:**
- Add strategic logging at state transition points: chunk received, stream done, tool detected
- Log both success and failure cases to understand flow
- Check `socket.assigns` values at each step (streaming_message, streaming_events, message_id)
- Test with various LLM response speeds (fast/slow streaming)
- Verify UI state matches backend state (loading indicators, message counts)

**On JSON-RPC error handling:**
- When MCP tools fail silently, check response format first (keys, structure)
- Use `Jason.encode!/1` to verify what actually gets sent over wire
- Test both success and error response paths
- Include enough context in error messages for remote debugging

---

## User Impact

**Before:**
- User: "List files in ~/devel/ollama_chat"
- LLM: `{"tool_call": {"name": "list_directory", "arguments": {"path": "~/devel/ollama_chat"}}}`
- Result: Raw JSON displayed, no tool execution, no file listing

**After:**
- User: "List files in ~/devel/ollama_chat"
- LLM: [Brief decision or empty message]
- [Tool execution indicator in activity section]
- LLM: "The ollama_chat directory contains 28 files including: .claude, .git, assets, config, lib, test..."
- Result: ✅ Natural conversation flow with actual file listing

---

## Related Issues

This fix builds on previous work:
- **2026-04-14-mcp-filesystem-absolute-relative-paths.md** — Added path resolution with `~`, `$HOME`, absolute, and relative path support
- Path resolution is now verified to work correctly when tool calls are actually executed
- Workspace configuration properly passed from MCP client to filesystem server

---

## Commits

1. **Filesystem server atom keys → string keys** — Convert all response maps to use string keys for MCP protocol compliance
2. **Add tool call detection to stream_done** — Catch tool calls that complete at end of stream
3. **Proper state cleanup before tool execution** — Finalize message and clear streaming state before executing tool

Files modified:
- `mcp_test_server/lib/mcp_test_server/servers/filesystem.ex` (17 handler functions)
- `lib/ollama_chat_web/live/chat_live.ex` (`handle_info` for stream_done, new `finalize_stream_as_message/3`)

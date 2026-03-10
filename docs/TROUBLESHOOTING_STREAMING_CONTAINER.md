# Troubleshooting: Streaming Container Display Issues

**Last Updated**: February 27, 2024  
**Feature**: Collapsible Streaming Container  
**Status**: ✅ Fixed

---

## Problem: Container Appears on ALL Messages

### Symptoms
- Collapsible intermediate responses container shows on every assistant message in the conversation
- Old messages display "Intermediate responses (N updates)" even though they're not streaming
- The same streaming data appears on multiple messages simultaneously

### Root Cause
The `@streaming_chunks` assign is stored at the **socket level**, not per-message. When the template iterates through all messages with `phx-update="stream"`, each message checks the same global `@streaming_chunks` list.

**Before the fix:**
```heex
<%= if message.streaming and length(@streaming_chunks) > 1 do %>
  <!-- Container appears on ANY message with streaming: true -->
<% end %>
```

This meant:
- Every message with `streaming: true` would check `@streaming_chunks`
- Old messages that were never fully cleared would show the container
- Multiple containers could appear simultaneously

### Solution: Track Message ID

Added `streaming_message_id` assign to identify which specific message is currently streaming:

```elixir
# In mount/3 and reset functions
|> assign(:streaming_message_id, nil)

# When streaming starts (handle_event "send_message")
|> assign(:streaming_message_id, assistant_message_id)

# When streaming completes (handle_info :stream_done)
|> assign(:streaming_message_id, nil)
```

**Template fix (Line 1371):**
```heex
<%= if message.id == @streaming_message_id and message.streaming and length(@streaming_chunks) > 1 do %>
  <!-- Container only appears on the CURRENT streaming message -->
<% end %>
```

### Verification Steps

1. **Check the template condition** (line 1371 in `chat_live.ex`):
   ```heex
   <%= if message.id == @streaming_message_id and ... %>
   ```
   Must include `message.id == @streaming_message_id` check first.

2. **Check mount initialization** (line 40):
   ```elixir
   |> assign(:streaming_message_id, nil)
   ```

3. **Check streaming start** (line 260):
   ```elixir
   |> assign(:streaming_message_id, assistant_message_id)
   ```

4. **Check streaming completion** (line 554):
   ```elixir
   |> assign(:streaming_message_id, nil)
   ```

---

## Problem: Container Never Appears

### Symptoms
- No collapsible container shows during streaming
- Only the main message bubble with cursor is visible
- Streaming works, but no intermediate responses container

### Possible Causes

#### 1. Not Enough Chunks
**Check**: Container only shows when `length(@streaming_chunks) > 1`

**Reason**: Need at least 2 chunks to have "intermediate" responses (current chunk is shown in main bubble)

**Solution**: Normal behavior for short responses. Try longer prompts.

#### 2. Missing streaming_message_id Assignment
**Check**: Line 260 should set `streaming_message_id` when sending message

```elixir
socket =
  socket
  |> assign(:streaming_chunks, [])
  |> assign(:streaming_message_id, assistant_message_id)  # ← Must be set
```

#### 3. Template Condition Too Strict
**Check**: Line 1371 template condition

```heex
<%= if message.id == @streaming_message_id and message.streaming and length(@streaming_chunks) > 1 do %>
```

All three conditions must be true:
- `message.id == @streaming_message_id` ✓
- `message.streaming` ✓
- `length(@streaming_chunks) > 1` ✓

#### 4. Chunks Not Being Captured
**Check**: `stream_normal_chunk/3` function (lines 478-520)

```elixir
defp stream_normal_chunk(socket, message_id, new_content) do
  current_chunks = socket.assigns.streaming_chunks
  
  updated_chunks =
    if current_chunks == [] or List.last(current_chunks) != new_content do
      current_chunks ++ [new_content]  # ← Should append chunks
    else
      current_chunks
    end
  
  socket
  |> assign(:streaming_chunks, updated_chunks)  # ← Must assign updated chunks
end
```

---

## Problem: Container Shows Stale Data

### Symptoms
- Container shows data from previous conversation
- Chunk count doesn't reset between messages
- Old intermediate responses visible in new streaming session

### Causes and Fixes

#### 1. Not Cleared on Stream Completion
**Check**: Line 554 in `handle_info({:stream_done, ...})`

```elixir
socket
|> assign(:streaming_chunks, [])         # ← Must clear
|> assign(:streaming_message_id, nil)    # ← Must clear
```

#### 2. Not Cleared on Cancellation
**Check**: Line 127 in `handle_event("cancel_stream", ...)`

```elixir
socket
|> assign(:streaming_chunks, [])         # ← Must clear
|> assign(:streaming_message_id, nil)    # ← Must clear
```

#### 3. Not Cleared on New Conversation
**Check**: Line 1936 in `start_new_conversation/1`

```elixir
socket
|> assign(:streaming_chunks, [])         # ← Must clear
|> assign(:streaming_message_id, nil)    # ← Must clear
```

#### 4. Not Cleared on Errors
**Check**: Lines 588 and 804 in error/timeout handlers

```elixir
socket
|> assign(:streaming_chunks, [])         # ← Must clear
|> assign(:streaming_message_id, nil)    # ← Must clear
```

---

## Problem: Cancel Button Doesn't Revert to Send

### Symptoms
- Cancel button stays red after streaming completes
- Cannot send new messages
- Button says "Cancel" even when not streaming

### Cause
`streaming_pid` not cleared when streaming finishes.

### Fix
**Check**: Line 559 in `handle_info({:stream_done, ...})`

```elixir
socket
|> assign(:streaming_pid, nil)  # ← Must clear to show Send button
```

The button logic:
```heex
<%= if @streaming_pid do %>
  <button phx-click="cancel_stream">Cancel</button>
<% else %>
  <button phx-click="send_message">Send</button>
<% end %>
```

---

## Problem: Chunks Not Updating in Container

### Symptoms
- Container appears but shows empty or wrong data
- Chunk count doesn't increase during streaming
- No updates visible when opening container

### Causes and Fixes

#### 1. Chunks Not Being Appended
**Check**: Line 484-488 in `stream_normal_chunk/3`

```elixir
updated_chunks =
  if current_chunks == [] or List.last(current_chunks) != new_content do
    current_chunks ++ [new_content]  # ← Appends to list
  else
    current_chunks  # ← Prevents duplicate if content unchanged
  end
```

#### 2. Assignment Missing
**Check**: Line 517 in `stream_normal_chunk/3`

```elixir
socket
|> assign(:streaming_chunks, updated_chunks)  # ← Must assign
```

#### 3. LiveView Not Receiving Chunks
**Check logs for**:
```
[debug] Streaming: message_id=..., chunks=N, content_length=...
```

If no logs, the issue is upstream (Ollama not sending, network problem, etc.)

---

## Debugging Checklist

### Quick Verification
Run through this checklist to verify the feature is working:

- [ ] Template includes `message.id == @streaming_message_id` check (line 1371)
- [ ] Mount initializes `streaming_message_id: nil` (line 40)
- [ ] Send message sets `streaming_message_id` to assistant ID (line 260)
- [ ] Stream done clears `streaming_message_id` to nil (line 554)
- [ ] Cancel clears `streaming_message_id` to nil (line 127)
- [ ] Stream normal chunk appends to `streaming_chunks` (line 487)
- [ ] All error handlers clear both assigns (lines 588, 804, etc.)

### Testing Steps

1. **Basic streaming**:
   - Send a message
   - Verify container appears after 2-3 chunks
   - Verify only on the new message (not old messages)
   - Wait for completion
   - Verify container disappears

2. **Multiple messages**:
   - Send first message, let it complete
   - Send second message
   - Verify container only on second message
   - Verify first message has final response only

3. **Cancellation**:
   - Send a message
   - Click Cancel mid-stream
   - Verify streaming stops
   - Verify chunks are cleared
   - Verify Send button returns

4. **New conversation**:
   - Have a conversation with streaming
   - Start new conversation
   - Verify no stale chunks appear
   - Verify streaming_message_id is nil

### Debug Logging

Add temporary logging to track state:

```elixir
# In stream_normal_chunk/3
Logger.debug("Chunks: #{length(updated_chunks)}, Current msg ID: #{message_id}, Streaming msg ID: #{inspect(socket.assigns.streaming_message_id)}")

# In handle_info(:stream_done, ...)
Logger.debug("Stream done, clearing streaming_message_id")
```

Check logs while testing to see state changes in real-time.

---

## Common Mistakes

### ❌ Forgetting Message ID Check
```heex
<!-- WRONG: Shows on all messages -->
<%= if message.streaming and length(@streaming_chunks) > 1 do %>
```

### ✅ Correct Implementation
```heex
<!-- CORRECT: Shows only on current message -->
<%= if message.id == @streaming_message_id and message.streaming and length(@streaming_chunks) > 1 do %>
```

### ❌ Not Clearing on All Paths
```elixir
# WRONG: Only clears streaming_chunks, not ID
socket
|> assign(:streaming_chunks, [])
```

### ✅ Correct Implementation
```elixir
# CORRECT: Clears both
socket
|> assign(:streaming_chunks, [])
|> assign(:streaming_message_id, nil)
```

### ❌ Setting ID After spawn
```elixir
# WRONG: streaming_pid set but streaming_message_id still nil
pid = spawn(fn -> ... end)
socket
|> assign(:streaming_pid, pid)
# Missing: |> assign(:streaming_message_id, assistant_message_id)
```

### ✅ Correct Implementation
```elixir
# CORRECT: Both set together
pid = spawn(fn -> ... end)
socket
|> assign(:streaming_pid, pid)
|> assign(:streaming_message_id, assistant_message_id)
```

---

## Expected Behavior

### Correct Visual Flow

**During Streaming:**
```
┌─────────────────────────────────────┐
│ User: Write a poem about trees      │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ ▶ 🔄 Intermediate responses (5 updates) │ ← Only on new message
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Trees stand tall in forests...█     │ ← Current content
└─────────────────────────────────────┘

[Cancel] ← Red button
```

**After Completion:**
```
┌─────────────────────────────────────┐
│ User: Write a poem about trees      │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Trees stand tall in forests green,  │ ← Final response only
│ Their branches sway...               │    (no container)
└─────────────────────────────────────┘

[Send] ← Blue button
```

### State at Each Stage

| Stage | streaming_chunks | streaming_message_id | streaming_pid | loading |
|-------|------------------|---------------------|---------------|---------|
| Idle | `[]` | `nil` | `nil` | `false` |
| Start | `[]` | `"msg-123"` | `<pid>` | `true` |
| Chunk 1 | `["Hello"]` | `"msg-123"` | `<pid>` | `true` |
| Chunk 2 | `["Hello", "Hello,"]` | `"msg-123"` | `<pid>` | `true` |
| Done | `[]` | `nil` | `nil` | `false` |

---

## Related Documentation

- **Feature Guide**: `FEATURE_STREAMING_CONTAINER.md`
- **Quick Reference**: `QUICK_REF_STREAMING_CONTAINER.md`
- **Session Notes**: `SESSION_2024-02-27b_STREAMING_CONTAINER.md`

---

## Getting Help

If issues persist after following this guide:

1. Check all 196 tests pass: `mix test`
2. Review commit that added the fix
3. Compare your implementation against the correct code locations listed
4. Add debug logging to track state changes
5. Check browser console for JavaScript errors (if policy allows)

**Status**: This issue is resolved in the current implementation. All fixes documented here are already applied in the codebase.
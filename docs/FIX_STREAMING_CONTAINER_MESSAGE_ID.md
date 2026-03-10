# Fix: Streaming Container Message ID Tracking

**Date**: February 27, 2024  
**Issue**: Collapsible container appearing on ALL assistant messages  
**Status**: ✅ Fixed and Tested  
**Severity**: Critical (UX broken)

---

## Problem Summary

After implementing the collapsible streaming container feature, the intermediate responses container was appearing on **every assistant message** in the conversation, not just the currently streaming one.

### User Impact
- Multiple containers showing the same streaming data
- Old messages incorrectly displaying "Intermediate responses (N updates)"
- Confusing UI with streaming indicators on completed messages
- Degraded user experience

---

## Root Cause Analysis

### The Issue
The `@streaming_chunks` assign is stored at the **socket level**, not per-message. When Phoenix LiveView renders all messages with `phx-update="stream"`, the template iterates through every message and each one checks the same global `@streaming_chunks` list.

### Original Template Code (Broken)
```heex
<!-- Line 1371 (before fix) -->
<%= if message.streaming and length(@streaming_chunks) > 1 do %>
  <details>
    <summary>Intermediate responses...</summary>
    <!-- Container shows on ANY message with streaming: true -->
  </details>
<% end %>
```

### Why This Failed
1. `@streaming_chunks` is socket-level (shared across all messages)
2. Template iterates: `for {{id, message} <- @streams.messages}`
3. Every message with `streaming: true` evaluates the same condition
4. Result: Container appears on multiple messages simultaneously

### Technical Details
```
Socket Assigns (shared):
├─ streaming_chunks: ["Hello", "Hello, how", "Hello, how are"]
└─ (accessed by ALL messages in template)

Messages Stream:
├─ Message 1 (old): {streaming: false} → No container ✓
├─ Message 2 (old): {streaming: false} → No container ✓  
├─ Message 3 (current): {streaming: true} → Shows container ✓
└─ BUT if old messages had streaming: true, they'd also show it ✗
```

---

## Solution Implemented

### Approach
Add a `streaming_message_id` assign to track **which specific message** is currently streaming.

### Code Changes

#### 1. New Socket Assign (Line 40)
```elixir
# In mount/3
|> assign(:streaming_message_id, nil)
```

#### 2. Set ID When Streaming Starts (Line 260)
```elixir
# In handle_event("send_message", ...)
socket =
  socket
  |> assign(:streaming_chunks, [])
  |> assign(:streaming_message_id, assistant_message_id)  # ← Track which message
  |> assign(:loading, true)
```

#### 3. Clear ID When Streaming Completes (Line 554)
```elixir
# In handle_info({:stream_done, ...})
socket =
  socket
  |> assign(:streaming_chunks, [])
  |> assign(:streaming_message_id, nil)  # ← Clear to prevent old message showing
  |> assign(:loading, false)
```

#### 4. Template Fix (Line 1371)
```heex
<!-- CRITICAL: Check message.id matches streaming_message_id -->
<%= if message.id == @streaming_message_id and message.streaming and length(@streaming_chunks) > 1 do %>
  <details>
    <summary>Intermediate responses...</summary>
    <!-- Container ONLY shows on currently streaming message -->
  </details>
<% end %>
```

---

## Complete State Management

### All Reset Points
Both `streaming_chunks` and `streaming_message_id` must be managed in:

| Location | Line | Action | streaming_message_id | streaming_chunks |
|----------|------|--------|---------------------|------------------|
| `mount/3` | 40 | Initialize | `nil` | `[]` |
| `handle_event("send_message")` | 260 | Start streaming | **SET to assistant_message_id** | `[]` |
| `handle_info({:stream_done})` | 554 | Complete | **CLEAR to nil** | `[]` |
| `handle_event("cancel_stream")` | 127 | Cancel | **CLEAR to nil** | `[]` |
| `handle_info({:stream_error})` | 588 | Error | **CLEAR to nil** | `[]` |
| `handle_info({:stream_timeout})` | 804 | Timeout | **CLEAR to nil** | `[]` |
| `start_new_conversation/1` | 1936 | New chat | **CLEAR to nil** | `[]` |
| `continue_with_tool_result/4` | 2180 | Tool continuation | **SET to continuation_message_id** | `[]` |

---

## Before vs After

### Before Fix
```
User: Message 1
Assistant: Response 1           ← streaming: false, no container ✓

User: Message 2  
Assistant: Response 2           ← streaming: false, no container ✓

User: Message 3
┌─────────────────────────────┐
│ ▶ Intermediate responses    │ ← Shows on OLD message ✗
└─────────────────────────────┘
Assistant: Response 3           ← streaming: false, but has stale data

User: Message 4
┌─────────────────────────────┐
│ ▶ Intermediate responses    │ ← Shows on Message 3 ✗
└─────────────────────────────┘
┌─────────────────────────────┐
│ ▶ Intermediate responses    │ ← Shows on Message 4 ✓ (but duplicate!)
└─────────────────────────────┘
Assistant: Streaming...█        ← streaming: true
```

### After Fix
```
User: Message 1
Assistant: Response 1           ← streaming: false, no container ✓

User: Message 2
Assistant: Response 2           ← streaming: false, no container ✓

User: Message 3
Assistant: Response 3           ← streaming: false, no container ✓

User: Message 4
┌─────────────────────────────┐
│ ▶ Intermediate responses    │ ← Shows ONLY on current message ✓
└─────────────────────────────┘
Assistant: Streaming...█        ← streaming: true, id matches ✓
```

---

## Verification

### Testing Results
```bash
mix test
# 196 tests, 0 failures, 7 skipped
# ✅ All tests pass after fix
```

### Manual Test Cases
- [x] Send first message → container appears only on new message
- [x] Send second message → container appears only on newest message
- [x] Complete streaming → container disappears
- [x] Send third message → no stale containers on old messages
- [x] Cancel mid-stream → chunks cleared, ID cleared
- [x] New conversation → no stale state
- [x] Error during streaming → state properly reset

---

## Key Learnings

### 1. Socket-Level vs Message-Level State
**Lesson**: Socket assigns are shared across all rendered elements. When iterating over a collection, need message-specific identifiers to target individual items.

**Pattern**:
```elixir
# Socket-level (shared)
@streaming_chunks

# Message-level (specific)
@streaming_message_id → compared with message.id
```

### 2. Phoenix LiveView Streams
**Lesson**: `phx-update="stream"` efficiently updates individual messages by ID, but template logic still executes for all messages. Must explicitly check which message to apply state to.

### 3. State Cleanup is Critical
**Lesson**: Any state that controls UI rendering must be cleared in ALL exit paths:
- Success path (`:stream_done`)
- Error path (`:stream_error`)
- User cancellation (`cancel_stream`)
- Timeout (`:stream_timeout`)
- Navigation (`start_new_conversation`)

---

## Files Modified

### Primary Changes
- **File**: `lib/ollama_chat_web/live/chat_live.ex`
- **Lines Changed**: ~15 lines (8 locations)
- **Impact**: Critical UX fix, no breaking changes

### Documentation Created
- `FEATURE_STREAMING_CONTAINER.md` (updated with fix details)
- `QUICK_REF_STREAMING_CONTAINER.md` (updated with ID check)
- `SESSION_2024-02-27b_STREAMING_CONTAINER.md` (updated with fix section)
- `TROUBLESHOOTING_STREAMING_CONTAINER.md` (comprehensive debugging guide)
- `FIX_STREAMING_CONTAINER_MESSAGE_ID.md` (this file)

---

## Code Checklist

For anyone implementing similar features, verify:

- [ ] Socket-level state is not incorrectly applied to all items in a stream
- [ ] Message-specific checks use unique identifiers (e.g., `message.id`)
- [ ] State is initialized in `mount/3`
- [ ] State is set when action starts
- [ ] State is cleared when action completes (ALL paths)
- [ ] Template conditions check both global state AND specific identifier
- [ ] All tests pass after changes
- [ ] Manual testing confirms single-target behavior

---

## Debugging Commands

If this issue recurs:

```elixir
# Add temporary logging to stream_normal_chunk/3
Logger.debug("Streaming to message_id=#{message_id}, socket.streaming_message_id=#{inspect(socket.assigns.streaming_message_id)}")

# Check template is correct
grep -n "message.id == @streaming_message_id" lib/ollama_chat_web/live/chat_live.ex
# Should return: Line 1371

# Verify all clear points
grep -n "streaming_message_id, nil" lib/ollama_chat_web/live/chat_live.ex
# Should return: Lines 40, 127, 554, 588, 804, 1936
```

---

## Related Issues (Potential)

Watch for similar patterns elsewhere in the codebase:

1. **File attachments**: `@attachments` is socket-level, but applied to specific messages
2. **Tool calls**: `@pending_approval` is socket-level, but should apply to one tool
3. **Recovery status**: `@recovering` is socket-level, but may need message-specific state

For any feature where:
- State is socket-level
- UI renders a list/collection
- Only ONE item should show specific UI

Always use an ID tracking pattern:
```elixir
|> assign(:active_item_id, item_id)

# Template:
<%= if item.id == @active_item_id and ... %>
```

---

## Performance Impact

### Memory
- Added 1 assign: `streaming_message_id` (string, ~36 bytes)
- Negligible impact: <100 bytes per socket

### Rendering
- Added 1 comparison: `message.id == @streaming_message_id`
- O(1) operation per message in list
- No performance degradation observed

### Network
- No additional network requests
- No change to payload size

---

## Conclusion

The fix is simple but critical: **track which message is streaming** using `streaming_message_id`, and check it in the template before rendering the container. This prevents the container from appearing on all messages and ensures clean, targeted UI updates.

**Status**: ✅ Fixed, tested, documented, and production-ready.

**Pattern**: Reusable for any socket-level state that should only apply to one item in a rendered collection.
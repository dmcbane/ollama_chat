# Fix: Streaming Events Consolidation

**Date**: February 27, 2024  
**Issue**: Multiple intermediate items (tool calls, tool results, empty responses) not collected into single container  
**Status**: ✅ Fixed and Tested  
**Severity**: Critical (UX broken - cluttered interface)

---

## Problem Summary

After implementing the collapsible streaming container, tool calls and tool results were still appearing as separate collapsible containers throughout the conversation, creating visual clutter. Instead of a single consolidated container showing all intermediate activity, users saw multiple discrete containers:

### Before Fix (Broken UX)
```
1. Empty response (collapsed container)
2. "Calling tool: list_directory" (collapsed container)
3. "Tool completed: list_directory" (collapsed container)
4. Empty response (collapsed container)
5. "Calling tool: list_directory" (collapsed container)
6. "Tool completed: list_directory" (collapsed container)
7. Final response (visible)
```

**Result**: 6 separate intermediate items, with 4 in collapsed containers and 2 as empty responses.

### User Impact
- Cluttered interface with many collapsed containers
- Difficult to understand the conversation flow
- Hard to distinguish intermediate steps from final response
- Poor UX during MCP tool interactions

---

## Root Cause Analysis

### The Original Approach
The initial implementation only tracked **text streaming chunks** (`streaming_chunks: []`), which stored the progressive text response from the LLM.

### What We Missed
During MCP tool interactions, the system creates **separate message entries** for:
1. Tool call messages (`role: "tool_call"`)
2. Tool result messages (`role: "tool_result"`)
3. Empty responses (when tool calls are detected mid-stream)

These were inserted as **distinct messages** in the Phoenix LiveView stream:

```elixir
# Old approach - separate messages
tool_call_message = %{
  id: "#{message_id}-tool-call",
  role: "tool_call",
  content: "Calling tool: #{tool_name}",
  tool_name: tool_name,
  args: args,
  timestamp: DateTime.utc_now()
}

socket = stream_insert(socket, :messages, tool_call_message)
```

Each separate message rendered its own collapsible container, resulting in the cluttered UI.

### Why the Original Fix Didn't Work
The `streaming_chunks` list only captured text content during streaming:
- ✅ Collected text chunks: `["Hello", "Hello, how", "Hello, how are"]`
- ❌ Missed tool calls (separate messages)
- ❌ Missed tool results (separate messages)
- ❌ Missed empty responses (separate containers)

---

## Solution Implemented

### Conceptual Change
Instead of tracking only **text chunks**, we now track **all intermediate events** as structured data.

**Changed**: `streaming_chunks` → `streaming_events`

### New Data Structure

```elixir
# streaming_events is a list of event maps
streaming_events: [
  %{type: :chunk, content: "Hello", timestamp: ~U[...]},
  %{type: :chunk, content: "Hello, how", timestamp: ~U[...]},
  %{type: :tool_call, tool_name: "list_directory", args: %{path: "."}, timestamp: ~U[...]},
  %{type: :tool_result, tool_name: "list_directory", content: "file1.txt\nfile2.txt", timestamp: ~U[...]},
  %{type: :chunk, content: "The files are...", timestamp: ~U[...]}
]
```

### Event Types
1. **`:chunk`** - Progressive text response from LLM
2. **`:tool_call`** - MCP tool invocation with arguments
3. **`:tool_result`** - MCP tool execution result

---

## Code Changes

### 1. Renamed and Restructured State (Lines 38, 125, 259, etc.)

```elixir
# Before
|> assign(:streaming_chunks, [])

# After
|> assign(:streaming_events, [])
```

### 2. Enhanced Text Chunk Tracking (Lines 481-523)

```elixir
defp stream_normal_chunk(socket, message_id, new_content) do
  current_events = socket.assigns.streaming_events
  last_event = List.last(current_events)

  # Check if we should add this chunk
  should_add =
    current_events == [] or
      (last_event && last_event.type == :chunk && last_event.content != new_content) or
      (last_event && last_event.type != :chunk)

  updated_events =
    if should_add do
      current_events ++ [%{type: :chunk, content: new_content, timestamp: DateTime.utc_now()}]
    else
      current_events
    end

  socket
  |> assign(:streaming_events, updated_events)
  # ...
end
```

**Key improvement**: Events are now structured maps with `type`, `content`, and `timestamp`.

### 3. Tool Call Event Tracking (Lines 2099-2119)

```elixir
# Before - created separate message
defp execute_mcp_tool(socket, message_id, tool_name, args) do
  tool_call_message = %{
    id: "#{message_id}-tool-call",
    role: "tool_call",
    content: "Calling tool: #{tool_name}",
    tool_name: tool_name,
    args: args,
    timestamp: DateTime.utc_now()
  }
  
  socket = stream_insert(socket, :messages, tool_call_message)
  # ...
end

# After - adds to streaming events
defp execute_mcp_tool(socket, message_id, tool_name, args) do
  current_events = socket.assigns.streaming_events

  updated_events =
    current_events ++
      [
        %{
          type: :tool_call,
          tool_name: tool_name,
          args: args,
          timestamp: DateTime.utc_now()
        }
      ]

  socket = assign(socket, :streaming_events, updated_events)
  # ...
end
```

**Critical change**: Tool calls no longer create separate stream messages; they're added to the events list.

### 4. Tool Result Event Tracking (Lines 706-722)

```elixir
# Before - created separate message
def handle_info({:tool_result, message_id, tool_name, result}, socket) do
  tool_result_message = %{
    id: "#{message_id}-tool-result",
    role: "tool_result",
    content: format_tool_result(result),
    tool_name: tool_name,
    timestamp: DateTime.utc_now()
  }

  socket = stream_insert(socket, :messages, tool_result_message)
  # ...
end

# After - adds to streaming events
def handle_info({:tool_result, message_id, tool_name, result}, socket) do
  current_events = socket.assigns.streaming_events

  updated_events =
    current_events ++
      [
        %{
          type: :tool_result,
          tool_name: tool_name,
          content: format_tool_result(result),
          timestamp: DateTime.utc_now()
        }
      ]

  socket = assign(socket, :streaming_events, updated_events)
  # ...
end
```

### 5. Enhanced Template Rendering (Lines 1379-1434)

```heex
<%!-- Show collapsible intermediate events while streaming --%>
<%= if message.id == @streaming_message_id and message.streaming and length(@streaming_events) > 1 do %>
  <details class="bg-slate-800/50 border border-slate-600 rounded-lg max-w-2xl">
    <summary class="px-4 py-2 cursor-pointer hover:bg-slate-700/50 rounded-lg transition-colors flex items-center gap-2 text-sm text-slate-400">
      <.icon name="hero-chevron-right" class="w-4 h-4 details-chevron" />
      <.icon name="hero-arrow-path" class="w-4 h-4 text-slate-400 animate-spin" />
      <span>
        Intermediate activity ({length(@streaming_events) - 1} events)
      </span>
    </summary>
    
    <div class="px-4 py-3 border-t border-slate-600 space-y-3 max-h-96 overflow-y-auto">
      <%= for {event, idx} <- Enum.with_index(@streaming_events) do %>
        <%= if idx < length(@streaming_events) - 1 do %>
          <%= cond do %>
            <%# Text chunk event %>
            <% event.type == :chunk -> %>
              <div class="text-xs text-slate-300 border-l-2 border-slate-600 pl-3 py-1">
                <div class="text-slate-500 mb-1">Response update {idx + 1}</div>
                <div class="whitespace-pre-wrap break-words">{event.content}</div>
              </div>
              
            <%# Tool call event %>
            <% event.type == :tool_call -> %>
              <div class="text-xs border-l-2 border-blue-600 pl-3 py-1">
                <div class="text-blue-400 mb-1 flex items-center gap-1">
                  <.icon name="hero-wrench-screwdriver" class="w-3 h-3" />
                  Calling tool: <span class="font-mono">{event.tool_name}</span>
                </div>
                <%= if event[:args] && map_size(event.args) > 0 do %>
                  <pre class="text-xs text-blue-300 bg-slate-900/50 rounded p-1 mt-1">{inspect(event.args, pretty: true, limit: 3)}</pre>
                <% end %>
              </div>
              
            <%# Tool result event %>
            <% event.type == :tool_result -> %>
              <div class="text-xs border-l-2 border-green-600 pl-3 py-1">
                <div class="text-green-400 mb-1 flex items-center gap-1">
                  <.icon name="hero-check-circle" class="w-3 h-3" />
                  Tool completed: <span class="font-mono">{event.tool_name}</span>
                </div>
                <pre class="text-xs text-green-300 bg-slate-900/50 rounded p-1 mt-1 max-h-20 overflow-y-auto">{String.slice(event.content, 0, 200)}<%= if String.length(event.content) > 200, do: "..." %></pre>
              </div>
              
            <% true -> %>
              <div class="text-xs text-slate-400 italic">Unknown event type</div>
          <% end %>
        <% end %>
      <% end %>
    </div>
  </details>
<% end %>

<%!-- Main streaming/final response --%>
<div class="relative">
  <div class="bg-slate-700 text-white rounded-2xl rounded-tl-sm px-6 py-3 max-w-[80%] shadow-lg">
    <%= if message.streaming do %>
      <p class="whitespace-pre-wrap break-words">{message.content}</p>
      <span class="inline-block w-2 h-4 bg-white ml-1 animate-pulse"></span>
    <% else %>
      <div class="prose-chat">{raw(message.html_content)}</div>
    <% end %>
  </div>
</div>
```

**Visual improvements**:
- Color-coded events (slate=text, blue=tool call, green=tool result)
- Icons for each event type
- Compact display with truncated long results
- Numbered text updates
- Tool arguments shown inline

---

## Before vs After

### Before Fix (6 separate items)
```
User: what files are in the directory

┌─────────────────────────────────────┐
│ (empty response container)          │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ ▶ Calling tool: list_directory      │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ ▶ Tool completed: list_directory    │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ (empty response container)          │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ ▶ Calling tool: list_directory      │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ ▶ Tool completed: list_directory    │
└─────────────────────────────────────┘
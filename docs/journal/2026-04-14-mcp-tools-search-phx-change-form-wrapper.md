# Dev Journal — MCP Tools Search: `phx-change` Requires Form Wrapper

**Date:** 2026-04-14
**Files changed:** `lib/ollama_chat_web/live/chat_live.ex`
**Session context:** Adding search/filter functionality to the MCP tools list in the Settings dialog.

---

## Problem Statement

Implemented an MCP tools search input with `phx-change="mcp_tool_search"` directly on an `<input>` element. The search appeared in the UI, but typing in the input field produced no events — no server logs, no UI updates, nothing. The `@mcp_tool_search` assign remained frozen at its initial empty string value.

A test button with `phx-click` in the same location worked perfectly, confirming that:
- ✅ Events CAN reach the server from this modal location
- ✅ LiveView connection is active
- ❌ Only `phx-change` on the standalone input was failing

Initial debugging showed:
```elixir
# This input produced NO events when typing:
<input
  type="text"
  name="query"
  value={@mcp_tool_search}
  phx-change="mcp_tool_search"
  phx-debounce="200"
  ...
/>
```

---

## Root Cause

**`phx-change` does not work reliably on standalone `<input>` elements** — it must be attached to a `<form>` element for LiveView's client-side JavaScript to properly attach event listeners.

This is especially true for inputs inside conditionally-rendered content (like modals that appear/disappear based on `@show_settings`). LiveView's JavaScript client may not attach listeners to standalone inputs in these contexts.

From Phoenix LiveView documentation and common patterns:
- ✅ `<form phx-change="event">` — reliable, standard pattern
- ❌ `<input phx-change="event">` — may work in simple cases, fails in complex DOM scenarios

Interestingly, the Memories tab search ALSO uses a standalone input with `phx-change`, which suggests this issue may be intermittent or context-dependent (possibly related to how the modal renders, CSS properties like `pointer-events-none` on parent containers, or timing of when LiveView hooks are attached).

---

## Fix

Wrap the input in a `<form>` and move the `phx-change` binding to the form element:

```diff
- <div class="relative mb-3">
-   <input
-     type="text"
-     name="query"
-     value={@mcp_tool_search}
-     phx-change="mcp_tool_search"
-     phx-debounce="200"
-     ...
-   />
- </div>

+ <form phx-change="mcp_tool_search" class="relative mb-3">
+   <input
+     type="text"
+     name="query"
+     value={@mcp_tool_search}
+     phx-debounce="200"
+     ...
+   />
+ </form>
```

The event handler receives params from all form inputs: `%{"query" => "search text"}`.

After this change:
- ✅ Typing in the search box triggers `handle_event("mcp_tool_search", %{"query" => query}, socket)`
- ✅ The `@mcp_tool_search` assign updates correctly
- ✅ The `filter_mcp_tools/2` function filters the tool list in real-time
- ✅ The UI re-renders showing filtered results

---

## Key Takeaways

**On LiveView `phx-change` best practices:**
- Always attach `phx-change` to a `<form>` element, not directly to `<input>` elements
- When the form changes, LiveView automatically sends all input values as a params map keyed by the `name` attribute
- This is the documented, supported pattern — standalone `phx-change` on inputs is unreliable

**On debugging LiveView event delivery:**
1. **Test with `phx-click` first** — Use a simple button to verify events CAN reach the server from that location
2. **Log the params structure** — Log `params` in the event handler to see exactly what LiveView is sending
3. **Check parent containers** — Properties like `pointer-events-none` on parent elements can block event propagation

**Pattern to follow:**
```elixir
# Search input pattern:
<form phx-change="search_event" phx-submit="search_event">
  <input type="text" name="query" value={@search_query} phx-debounce="200" />
</form>

def handle_event("search_event", %{"query" => query}, socket) do
  {:noreply, assign(socket, :search_query, query)}
end
```

**Why `phx-submit` is also included:**
- Allows Enter key to trigger immediate search (bypasses debounce)
- Falls back to the same event handler
- No additional code needed if the handler can be idempotent

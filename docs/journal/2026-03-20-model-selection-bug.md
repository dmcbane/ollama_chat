# Dev Journal — Model Selection Bug Investigation & Resolution

**Date:** 2026-03-20
**Files changed:** `lib/ollama_chat_web/live/chat_live.ex`
**Session context:** Multi-session investigation; root cause found and fixed in final session.

---

## Problem Statement

Users reported that changing the model in the dropdown had no effect — requests always executed against the default model (or the model the conversation was saved with). The complaint was consistent and reproducible: "I loaded a previous conversation, changed the model, then submitted a prompt. The model reverted to the previous and all of the responses indicated the same previous model."

---

## Architecture Background

The model selection system has three layers that must stay in sync:

1. **Server assign** — `socket.assigns.selected_model` is the source of truth for what model the API call uses. Set on mount and updated by several event handlers.
2. **JavaScript hook** — `.ModelSelector` on the `<select id="model-select">` element. Persists the user's preference to `localStorage` via `save_model_preference` server events. Restores it on page load via `model_preference_loaded` client event.
3. **DOM `selected` attribute** — HEEx renders `selected={model == @selected_model}` on `<option>` elements. The `updated()` hook callback re-asserts `select.value` from this attribute to defend against browsers resetting form state during morphdom patches.

The chat form and the model select are in separate parts of the DOM (sidebar vs. main content column), so there is no `<form>` ancestor wrapping the select.

---

## Investigation: What We Ruled Out

### Hypothesis 1 — `phx-change` not firing on a standalone select
`phx-change="select_model"` was placed directly on the `<select>` (not on a `<form>`). We verified this is supported in Phoenix LiveView 1.1.x — a standalone select serializes its own `name=value` pair and fires the named event. The handler matched the params correctly. This was not the root cause.

### Hypothesis 2 — `handle_event("select_model", ...)` pattern mismatch
The handler uses `%{"model" => model}`. With `name="model"` on the select, the params are `%{"model" => value, "_target" => ["model"]}`. The pattern match ignores `_target`, so it always matched. Not the root cause.

### Hypothesis 3 — `model_preference_loaded` overriding a user's selection
`mounted()` in the hook pushes `model_preference_loaded` with the localStorage value. The server handler:
```elixir
def handle_event("model_preference_loaded", %{"model" => saved_model}, socket) do
  selected = if saved_model in socket.assigns.available_models, do: saved_model,
             else: socket.assigns.selected_model
  {:noreply, assign(socket, :selected_model, selected)}
end
```
This could override a `select_model` event if `model_preference_loaded` arrived *after* `select_model` in the GenServer mailbox. However `mounted()` fires at page-load time, long before the user can interact, so this race window is effectively zero. Not the root cause for normal usage.

### Hypothesis 4 — `updated()` reverting the dropdown during streaming
The `updated()` hook callback was intended to re-assert the server's intended selection when browsers reset form state during morphdom patches. However, `updated()` only fires when the `<select>` element's subtree actually changes in a LiveView diff — i.e., only when `@available_models` or `@selected_model` changes. Streaming chunks do not change either of those assigns, so streaming does not trigger `updated()`. Not the root cause for the streaming scenario.

### Hypothesis 5 — KeyError crash masking the model selection
A separate crash was discovered in `handle_event("send", ...)`:
```
** (KeyError) key :role not found
```
`message_history` contains a mixture of atom-keyed maps (messages created in the current session) and string-keyed maps (messages loaded from a saved conversation via localStorage JSON deserialization). The `messages_for_api` build used `msg.role` (dot access — raises `KeyError` on non-struct maps).

**This crash caused the LiveView process to terminate and restart.** On restart, `selected_model` resets to the default. This explained *part* of the user experience: selecting a model, loading a conversation, then sending — crash — server restarts with default model.

**Fix applied:**
```elixir
# Before
%{role: msg.role, content: msg.content}

# After — handles both atom-keyed (new messages) and string-keyed (loaded from JSON)
%{role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]}
```

This fixed the crash but not the full model selection problem.

---

## Root Cause Found

After the crash fix, the bug persisted for the specific scenario of **loading a conversation then changing the model**.

The `conversation_loaded` event handler correctly restores `selected_model` from the saved conversation and pushes `save_model_preference` to sync localStorage:

```elixir
|> assign(:selected_model, conversation["model"] || socket.assigns.selected_model)
# ...
socket = push_event(socket, "save_model_preference", %{model: socket.assigns.selected_model})
```

The bug was in the JavaScript `save_model_preference` handler:

```javascript
// BROKEN
this.handleEvent("save_model_preference", ({ model }) => {
  localStorage.setItem(this.storageKey, model);
  this.pendingValue = null;  // <-- clears for ANY model confirmation, not just ours
});
```

**The race that caused the revert:**

1. User loads conversation (model: "qwen3.5:9b") — `conversation_loaded` queued to server
2. User changes dropdown to "deepseek-r1:8b" — `pendingValue = "deepseek-r1:8b"`, `select_model` queued
3. Client receives `conversation_loaded` response: DOM diff (sets `selected` attr to "qwen3.5:9b") + `save_model_preference("qwen3.5:9b")`
4. `updated()` fires after morphdom — correctly skips re-assertion because `pendingValue !== null`
5. **`save_model_preference("qwen3.5:9b")` fires — unconditionally clears `pendingValue = null`**
6. Any subsequent DOM update triggers `updated()` again — now `pendingValue === null`, sees `intended = "qwen3.5:9b"` (from the conversation_loaded diff, not yet superseded), `this.el.value = "deepseek-r1:8b"` — **reverts dropdown to "qwen3.5:9b"**
7. Server has not yet processed `select_model` — if the user submits now, `selected_model` is still "qwen3.5:9b"

The `save_model_preference` event fires in two situations:
- From `handle_event("select_model", ...)` — confirming the user's own choice
- From `handle_event("conversation_loaded", ...)` — restoring the conversation's saved model

The original code treated both the same way and cleared `pendingValue` on either. The confirmation for the *conversation's* model was incorrectly canceling the guard that protected the *user's pending change*.

---

## Resolution

### Fix 1 — Move model change from `phx-change` to explicit `pushEvent`

Removed `phx-change="select_model"` from the `<select>` element. Instead, the `.ModelSelector` hook's `change` event listener now pushes the event directly:

```javascript
this.el.addEventListener("change", () => {
  this.pendingValue = this.el.value;
  this.pushEvent("select_model", { model: this.el.value });
});
```

Both `pendingValue` assignment and the server event now happen atomically in the same callback, removing any timing gap between the two.

### Fix 2 — Only clear `pendingValue` when the server confirms our specific pending model

```javascript
this.handleEvent("save_model_preference", ({ model }) => {
  localStorage.setItem(this.storageKey, model);
  // Only clear pendingValue when the server confirms OUR pending selection.
  // If the confirmation is for a different model (e.g. from conversation_loaded),
  // preserve pendingValue so updated() won't revert our selection.
  if (this.pendingValue === null || model === this.pendingValue) {
    this.pendingValue = null;
  }
});
```

### Fix 3 — `updated()` dual-path clear

The `updated()` callback has a secondary path to clear `pendingValue` once the server's `selected` attribute catches up with our pending value (handles edge cases where the DOM diff races ahead of the event):

```javascript
updated() {
  if (this.pendingValue !== null) {
    const confirmed = Array.from(this.el.options).find(
      opt => opt.hasAttribute("selected") && opt.value === this.pendingValue
    );
    if (confirmed) this.pendingValue = null;
    return;  // Never revert while a change is pending
  }
  // Re-assert server's selection (browser form-state restoration defense)
  const intended = Array.from(this.el.options).find(opt => opt.hasAttribute("selected"));
  if (intended && this.el.value !== intended.value) {
    this.el.value = intended.value;
  }
}
```

---

## Additional Fix — `streaming_model` data integrity

As part of a larger plan executed in the same sessions, a related data-integrity fix was applied: `streaming_model` is now captured once at send time and used throughout the streaming lifecycle, preventing mid-stream dropdown changes from corrupting the model attribution on the completed message.

```elixir
# In mount/3
|> assign(:streaming_model, Application.get_env(:ollama_chat, :ollama_default_model, "llama3"))

# In handle_event("send", ...)
|> assign(:streaming_model, socket.assigns.selected_model)

# In stream_normal_chunk/3 and handle_info({:stream_done, ...})
model: socket.assigns.streaming_model  # was: socket.assigns.selected_model
```

---

## Key Takeaways

**On LiveView + JavaScript hook state management:**
- `push_event/3` fires for *any* caller on the server, not just the specific interaction you expect. When multiple server handlers push the same named event (here: `save_model_preference`), the client handler must inspect the event payload to determine whether it applies to the current client-side state.
- `updated()` on a LiveView hook fires whenever morphdom patches the hooked element's subtree. This is powerful for browser-state-restoration defense but creates a conflict window: between when the user makes a change and when the server confirms it, any intervening re-render would undo the user's action without `pendingValue` protection.
- Explicit `pushEvent` from a hook's own event listener is more reliable than `phx-change` for complex elements that also have hooks — the intent and event source live in one place.

**On Elixir map key safety:**
- `message_history` (and any in-memory collection that can be populated from multiple sources) must be accessed with `map[:atom_key] || map["string_key"]` rather than `map.field` (dot access). JSON deserialization always produces string keys; in-session construction uses atom keys. These maps coexist in the same list.

**On debugging LiveView + JS interaction bugs:**
- The `Logger.debug` in `handle_event("select_model", ...)` was added to confirm whether the server was actually receiving the event. Combined with the server-side `Logger.info` in `handle_event("send", ...)` logging `selected_model` at send time, this creates a two-point trace for model attribution issues.

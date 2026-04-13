# Dev Journal — Intermittent Test Failures: Application Env Race Condition

**Date:** 2026-04-13
**Files changed:** `lib/ollama_chat/memory/extractor.ex`, `test/ollama_chat/memory_extractor_test.exs`, `test/ollama_chat/builtin_tools_test.exs`, `test/ollama_chat/embeddings_test.exs`, `test/ollama_chat/memory_conversation_summary_test.exs`, `test/ollama_chat/memory_test.exs`, `test/ollama_chat/tool_router_test.exs`
**Session context:** Discovered during a UI improvement sprint; tests were failing 1–5 times per 10-run batch before the fix, 0 times after.

---

## Problem Statement

The test suite had intermittent failures that changed on every run. Affected tests spanned multiple unrelated modules:

- `OllamaChat.Memory.ExtractorTest` — "clamps importance values outside 0.0–1.0"
- `OllamaChat.Memory.ConversationSummaryTest` — basic schema tests ("requires conversation_id", "accepts message_count of zero", etc.)
- `OllamaChat.BuiltinToolsTest` — "Memory.Update execute/1 updates memory_type"
- `OllamaChat.EmbeddingsTest` — "generates embedding and stores it on the memory entry"

The failures looked unrelated on the surface and the test names suggested logic errors, but the affected assertions were all sound. Re-running the same tests in isolation always passed.

---

## Investigation

### Hypothesis 1 — DB state leakage between async tests

The first suspicion was that Ecto's SQL Sandbox wasn't isolating data correctly. All these modules use `DataCase` with `async: true`, which puts each test in its own sandboxed transaction.

**Ruled out.** The failing tests do not assert cross-test DB state. The failures were `{:error, :memory_disabled}` returns where `{:ok, ...}` was expected — a logic branch, not a data-visibility issue.

### Hypothesis 2 — Memory.enabled?() reading stale module attribute

`Memory.enabled?/0` reads from `Application.get_env(:ollama_chat, :memory_enabled, true)`. Could there be a compiled-in false value?

**Ruled out.** `Application.get_env` is always evaluated at call time, never compiled in.

### Hypothesis 3 — Application.put_env race between async modules (root cause)

Searching for `memory_enabled` across the test suite revealed **six `async: true` modules** that all contained tests of the form:

```elixir
Application.put_env(:ollama_chat, :memory_enabled, false)
on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)
```

`Application.put_env` writes to a single VM-wide environment table — there is no per-process or per-test isolation. The `on_exit` callback runs in a **spawned process after the test process exits**, not synchronously before the next test starts.

Under concurrent scheduling the following race is possible:

```
Module A test N:  put_env(memory_enabled, false)     ← global state corrupted
Module B test N:                         ← reads Memory.enabled?() → false
                                         ← with_db returns {:error, :memory_disabled}
                                         ← assertion {:ok, _} fails
Module A on_exit:                               restores memory_enabled=true  ← too late
```

The `with_db/1` helper in `Memory` checks `Memory.enabled?()` before executing any DB operation. When `memory_enabled` was `false` at read time, every `Memory.*` call returned `{:error, :memory_disabled}`. This hit `create_conversation_summary`, `create_memory`, `list_memories`, and similarity search equally — explaining why failures appeared across completely different test modules.

The modules involved and their test counts:

| Module | async | memory_enabled mutations |
|---|---|---|
| `memory_extractor_test.exs` | true | 3 |
| `memory_test.exs` | true | 6 |
| `builtin_tools_test.exs` | true | 5 |
| `tool_router_test.exs` | true | 5 |
| `embeddings_test.exs` | true | 1 |
| `memory_conversation_summary_test.exs` | true | 3 |
| `memory_maintenance_test.exs` | **false** | 5 — already safe |

---

## Root Cause

`Application.put_env` is global OTP Application state. It is not sandboxed per-test, per-process, or per-ExUnit context. Any `async: true` test that calls it creates a visibility window where concurrent tests in other modules read the mutated value before `on_exit` restores it.

---

## Resolution

Two-pronged fix matching the severity of each case.

### Fix 1 — Dependency injection for `memory_extractor_test.exs`

The Extractor module already used DI for `chat_fn` and `embedding_fn`. Extending the same pattern to `memory_enabled` allows tests to pass `memory_enabled: false` as an option instead of mutating global state:

```elixir
# Before
def extract_from_conversation(conversation_id, messages, opts \\ []) do
  if Memory.enabled?() do
    ...

# After
def extract_from_conversation(conversation_id, messages, opts \\ []) do
  enabled = Keyword.get(opts, :memory_enabled, Memory.enabled?())
  if enabled do
    ...
```

Same change applied to `summarize/3` and `deduplicate/2`. The three "disabled" tests in `memory_extractor_test.exs` were updated to pass `memory_enabled: false` as an option:

```elixir
# Before
Application.put_env(:ollama_chat, :memory_enabled, false)
on_exit(fn -> Application.put_env(:ollama_chat, :memory_enabled, true) end)
assert {:error, :memory_disabled} = Extractor.extract_from_conversation("conv", msgs, ...)

# After
assert {:error, :memory_disabled} =
  Extractor.extract_from_conversation("conv", msgs, ..., memory_enabled: false)
```

`memory_extractor_test.exs` stays `async: true` and is no longer a contamination source.

### Fix 2 — `async: false` for the five remaining modules

The other five modules have no equivalent injectable surface in their production code — they test `Memory.*` context functions that read `memory_enabled` inside `with_db`. Changing them to `async: false` runs them sequentially *after* all async tests complete.

In sequential mode (`async: false`), ExUnit guarantees `on_exit` callbacks complete before the next test in any module begins, eliminating the race entirely. All 334 tests in these modules use mocks and in-memory DB transactions; they complete in ~1.5 seconds sequential, adding negligible wall-clock time.

---

## Remaining Known Flakiness

`OllamaChatWeb.ChatLiveTest` — "streaming timeout clears loading and shows an error" fails roughly 1-in-20 runs. This is a pre-existing, documented timing race: when Ollama is not running, the spawned stream process sends `{:stream_error, ...}` before the test's manually-sent `{:stream_timeout, ...}` is processed, and the two paths interact. The test comment acknowledges this. It is unrelated to the `memory_enabled` issue and unaffected by this fix.

---

## Key Takeaways

**On `Application.put_env` in async tests:**
- `Application.put_env` is global VM state. It is categorically unsafe to use in `async: true` test modules unless the key being mutated is completely unique to that module and no other concurrent module reads it.
- The `on_exit` callback does not provide synchronous protection — it runs after the test process exits, not before the next test starts.
- The correct fix when production code reads `Application.get_env` is to add an injectable opt (`memory_enabled: false`) that tests can pass directly, following the same DI pattern used for external calls (`chat_fn`, `embedding_fn`). This is the only approach that keeps tests fully `async: true`.
- When adding the injectable opt is impractical (e.g., the config is read deep inside a shared helper like `with_db`), `async: false` is the correct fallback. Sequential tests are not a failure of design — they are the appropriate tool for code that has global side effects.

**On diagnosing flaky tests:**
- Failures that appear in completely unrelated test modules and disappear on isolated re-runs almost always indicate shared mutable state rather than logic errors.
- A systematic search for `Application.put_env` across all `async: true` modules is the first diagnostic step for this class of flakiness.
- Running the suite 5–10 times back-to-back before and after a proposed fix is necessary to confirm resolution. A single passing run is not sufficient.

# Known Issues

This document tracks known issues and intentional design decisions in the codebase.

## Function Grouping in ChatLive

**Status**: Intentional Design Decision  
**Priority**: N/A (Accepted pattern)  
**File**: `lib/ollama_chat_web/live/chat_live.ex`  
**Impact**: Advisory compiler warnings only

### Description

The Elixir compiler produces warnings that function clauses with the same name and arity are not grouped together in `ChatLive`:

```
warning: clauses with the same name and arity (number of arguments) should be grouped together, 
"def handle_info/2" was previously defined (lib/ollama_chat_web/live/chat_live.ex:303)
```

This occurs at four locations:
- Line 382: `handle_info({:stream_done, message_id}, socket)`
- Line 503: `handle_info({:recovery_progress, step}, socket)`
- Line 591: `handle_event("approve_tool", _params, socket)`
- Line 631: `handle_info(:clear_recovery_status, socket)`

**This is intentional and documented in the module's @moduledoc.**

### Root Cause

In Phoenix LiveView modules, it's common to organize callbacks by feature rather than by function name. For example, all tool-related functions (both `handle_event/3` and `handle_info/2`) might be grouped together in one section, while all streaming-related functions are in another section.

This creates a trade-off:
- **Grouping by function name** (Elixir convention): All `handle_event/3` together, all `handle_info/2` together
- **Grouping by feature** (LiveView readability): Tool functions together, streaming functions together, etc.

### Current Organization

The file is organized by feature:
1. Mount and initial setup
2. Event handlers (send message, select model, etc.)
3. Streaming handlers (chunk, done, error)
4. Recovery handlers
5. Tool handlers (both events and info messages)
6. MCP settings handlers

### Impact

- ⚠️ Compiler warnings during build (advisory only)
- ✅ Does not affect runtime behavior
- ✅ Does not affect code correctness
- ✅ Does not block builds (warnings are not treated as errors)
- ✅ Current organization is more maintainable
- ✅ Common pattern in large LiveView modules

### Solutions

#### Option 1: Reorganize by Function Name (Strict Elixir Style)

Group all `handle_event/3` clauses together, then all `handle_info/2` clauses:

**Pros:**
- No compiler warnings
- Follows strict Elixir conventions
- Passes `mix compile --warnings-as-errors`

**Cons:**
- Scatters related functionality across the file
- Harder to understand feature groupings
- Large files become harder to navigate
- Tool-related logic split between two distant sections

#### Option 2: Suppress Warning (Pragmatic Approach)

Accept the warning as acceptable for large LiveView modules:

```elixir
@compile {:no_warn_undefined_behaviour, handle_info: 2}
```

Or configure mix.exs to allow this pattern:

```elixir
elixirc_options: [warnings_as_errors: false]
```

**Pros:**
- Maintains current readable organization
- Features remain grouped together
- Easier to understand and modify

**Cons:**
- Breaks strict compilation rules
- Warning always visible
- Doesn't follow standard Elixir convention

#### Option 3: Extract to Separate Modules

Split `ChatLive` into smaller modules using LiveView components or separate concerns:

```elixir
defmodule ChatLive.ToolHandlers do
  # All tool-related handle_event and handle_info
end

defmodule ChatLive.StreamHandlers do
  # All streaming-related handle_info
end
```

**Pros:**
- Smaller, more focused modules
- Each module can group its own callbacks
- Better separation of concerns

**Cons:**
- Significant refactoring required
- May complicate LiveView state management
- Overhead of module boundaries

### Decision

**We accept these warnings.** The current feature-based organization is more maintainable for a complex LiveView module with 1900+ lines. The warnings do not indicate incorrect code, just a style preference.

This is documented in the module's `@moduledoc` to make the decision explicit for future developers.

If the file continues to grow significantly, consider **Option 3** (extracting concerns) as a long-term solution.

### No Workaround Needed

The `mix precommit` task already uses `compile` (not `compile --warnings-as-errors`), so these warnings don't block the precommit workflow.

```elixir
precommit: [
  "compile",  # Warnings are advisory
  "deps.unlock --unused",
  "format --check-formatted",
  "credo --min-priority high",
  "dialyzer",
  "test"
]
```

All quality checks pass successfully with these advisory warnings present.

## Other Issues

None at this time.

### Code Quality Metrics

With the accepted function grouping pattern:

- ✅ **196/196 tests passing** (100%)
- ✅ **0 Dialyzer errors**
- ✅ **0 Credo issues** (high priority)
- ✅ **Full test coverage** of critical paths
- ℹ️ **4 compiler warnings** (function grouping - intentional)

The codebase maintains high quality with comprehensive testing and type checking.

**Note**: These warnings are not quality issues - they reflect an intentional design decision that prioritizes maintainability over strict stylistic conventions.
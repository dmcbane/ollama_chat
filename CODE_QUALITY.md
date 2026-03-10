# Code Quality Guidelines

This document describes the code quality tools and practices used in the Ollama Chat project.

## Overview

We maintain high code quality through a combination of automated tools:

- **Elixir Compiler** - Treats warnings as errors in CI
- **Formatter** - Enforces consistent code style
- **Credo** - Static code analysis for best practices
- **Dialyzer** - Static type checking
- **ExUnit** - Comprehensive test coverage

## Quick Start

```bash
# Run all quality checks before committing
mix precommit

# Individual tools
mix compile
mix format --check-formatted
mix credo --strict  # or --min-priority high for CI
mix dialyzer
mix test
```

## Tools

### 1. Elixir Compiler

The compiler checks for common issues:

- No unused variables
- No undefined functions
- No pattern match warnings
- Functions are grouped by name/arity (advisory warning)

**Note**: Function grouping warnings are advisory in this project. In large LiveView modules, feature-based organization (grouping related `handle_event` and `handle_info` callbacks together) is prioritized over strict function name grouping for better maintainability.

**Configuration**: `mix.exs`

### 2. Mix Format

Enforces consistent code formatting across the entire codebase.

```bash
# Check formatting
mix format --check-formatted

# Auto-format all files
mix format
```

**Configuration**: `.formatter.exs`

### 3. Credo

Static analysis tool that checks for:

- Code consistency
- Design issues
- Readability problems
- Refactoring opportunities
- Common warnings

**Configuration**: `.credo.exs`

#### Current Status

- **0 issues in strict mode** ✅
- All previously identified issues have been resolved through refactoring
- See `CREDO_FIXES_SUMMARY.md` for detailed resolution information

The `precommit` task uses `--min-priority high` to only fail on critical issues.

#### Running Credo

<old_text line=78>
# Show all issues including low priority
mix credo list
```

```bash
# Run all checks
mix credo

# Run with strict mode
mix credo --strict

# Explain a specific issue
mix credo explain lib/path/to/file.ex:123

# Show all issues including low priority
mix credo list
```

#### Key Checks Enabled

- **Consistency**: Parameter patterns, spacing, naming conventions
- **Design**: Alias usage, avoid TODO/FIXME in production
- **Readability**: Module docs, function names, line length (120 chars)
- **Refactoring**: Cyclic complexity (max 12), nesting (max 3), pipe chains
- **Warnings**: Unused operations, unsafe code, operation on same values

### 4. Dialyzer

Static type checker that analyzes BEAM bytecode to find type inconsistencies, unreachable code, and other issues.

**Configuration**: `mix.exs` (dialyzer section)

#### Setup

```bash
# Build PLT (Persistent Lookup Table) - run once or when deps change
mix dialyzer --plt

# Run type checking
mix dialyzer
```

#### Configuration Details

```elixir
dialyzer: [
  plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
  plt_add_apps: [:mix, :ex_unit],
  flags: [
    :error_handling,    # Checks for poor error handling
    :underspecs,        # Warns about missing or incomplete specs
    :unmatched_returns  # Warns about ignored return values
  ],
  ignore_warnings: ".dialyzer_ignore.exs",
  list_unused_filters: true
]
```

#### Common Issues Fixed

1. **Unmatched Returns**: When return values are ignored
   ```elixir
   # Bad - ignores return value
   Process.send_after(self(), :msg, 1000)
   
   # Good - explicitly ignores
   _ref = Process.send_after(self(), :msg, 1000)
   ```

2. **Unreachable Patterns**: When pattern matches can never succeed
   ```elixir
   # Bad - 'other' clause unreachable
   case result do
     {:ok, _} -> :ok
     {:error, _} -> :error
     other -> :unreachable  # Dialyzer catches this
   end
   ```

3. **Type Mismatches**: When function specs don't match implementation
   ```elixir
   @spec get_tool(String.t()) :: map() | nil
   def get_tool(tool_name) do
     # Implementation must return map() or nil
   end
   ```

#### Ignoring Warnings

Use `.dialyzer_ignore.exs` sparingly for known issues that can't be fixed:

```elixir
[
  # Ignore specific warning at line
  {"lib/my_module.ex", :unknown_function, 42},
  
  # Ignore warning type in file
  {"lib/my_module.ex", :unknown_type},
  
  # Ignore warning type everywhere (use very carefully)
  {:unknown_function}
]
```

### 5. ExUnit Tests

Comprehensive test suite with 196 tests covering:

- MCP client functionality (20 tests)
- MCP prompt builder (24 tests)
- MCP response parser (52 tests)
- MCP registry (15 tests)
- LiveView chat functionality (85 tests)

```bash
# Run all tests
mix test

# Run specific test file
mix test test/ollama_chat/mcp_client_test.exs

# Re-run only failed tests
mix test --failed

# Run with coverage
mix test --cover
```

**Key Testing Patterns**:

- Use `start_supervised!/1` for processes (automatic cleanup)
- Use `Process.monitor/1` instead of `Process.sleep/1`
- Use `:sys.get_state/1` for synchronization
- Tag integration tests with `@tag :integration`

## Precommit Hook

The `mix precommit` task runs all quality checks:

```bash
mix precommit
```

This runs:
1. `mix compile` - Check compilation (warnings are advisory)
2. `mix deps.unlock --unused` - Remove unused dependencies
3. `mix format --check-formatted` - Verify code formatting
4. `mix credo --min-priority high` - Run static analysis (critical issues only)
5. `mix dialyzer` - Run type checking (zero tolerance)
6. `mix test` - Run test suite (must pass 100%)

**Philosophy**: The precommit task uses a pragmatic approach:
- **Zero tolerance**: Type errors (Dialyzer), test failures, formatting issues
- **Advisory**: Compiler warnings about function grouping, low-priority style issues
- **Balanced**: Focus on correctness and maintainability over strict style conformance

**Tip**: Run this before every commit to catch critical issues early.

## Type Specifications

We use `@spec` and `@type` annotations for public APIs:

```elixir
@type tool_name :: String.t()
@type tool_result :: {:ok, list()} | {:error, term()}

@spec call_tool(tool_name(), map()) :: tool_result()
def call_tool(tool_name, args) do
  # implementation
end
```

**Guidelines**:
- Add `@spec` for all public functions
- Add `@type` for custom types used in specs
- Use `@typedoc` to document complex types
- Keep specs accurate - Dialyzer will verify them

## Error Handling

**NEVER SWALLOW ERRORS** - Core principle from `AGENTS.md`

```elixir
# Bad - swallows errors silently
try do
  risky_operation()
rescue
  _ -> :ok
end

# Good - explicit error handling
case risky_operation() do
  {:ok, result} -> 
    {:ok, result}
  {:error, reason} -> 
    Logger.error("Operation failed: #{inspect(reason)}")
    {:error, reason}
end

# Good - let it crash (supervisor will handle)
def important_operation do
  result = risky_operation!()  # Raises on error
  process_result(result)
end
```

## Code Style

### Grouping Functions

Group function clauses with the same name/arity together:

```elixir
# Good
def handle_event("send", params, socket), do: ...
def handle_event("clear", _params, socket), do: ...

# Bad - spreads clauses across file
def handle_event("send", params, socket), do: ...
def mount(_params, _session, socket), do: ...
def handle_event("clear", _params, socket), do: ...  # Warning!
```

### Nesting Depth

Keep nesting depth ≤ 3 levels (Credo warns at 4):

```elixir
# Too nested (depth 4)
def process(data) do
  if valid?(data) do
    case transform(data) do
      {:ok, result} ->
        if special?(result) do
          case finalize(result) do  # Depth 4!
            {:ok, final} -> final
          end
        end
    end
  end
end

# Better - extract functions
def process(data) do
  with true <- valid?(data),
       {:ok, result} <- transform(data),
       true <- special?(result),
       {:ok, final} <- finalize(result) do
    final
  end
end
```

## Continuous Improvement

### Adding New Checks

When adding new Credo checks:

1. Review `.credo.exs` for available checks
2. Move check from `:disabled` to `:enabled`
3. Run `mix credo --strict` to see impact
4. Fix or adjust threshold as needed

### Updating Dependencies

When updating dependencies:

```bash
mix deps.update --all
mix dialyzer --plt  # Rebuild PLT
mix test
```

### Monitoring Quality

Track these metrics over time:

- Test count and pass rate
- Credo issue count by category
- Dialyzer warning count
- Code coverage percentage
- Lines of code vs lines of tests

## Resources

- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Credo Documentation](https://hexdocs.pm/credo)
- [Dialyzer Documentation](https://www.erlang.org/doc/man/dialyzer.html)
- [Dialyxir Hex Page](https://hexdocs.pm/dialyxir)
- [ExUnit Documentation](https://hexdocs.pm/ex_unit)

## Current Status

✅ **196/196 tests passing** (100% pass rate)
✅ **0 Dialyzer errors** (strict type checking)
✅ **0 Credo issues** (strict mode - all resolved)
✅ **4 compiler warnings** (function grouping - advisory only)
✅ **All code formatted**

The codebase maintains high quality standards with comprehensive tooling and automation. The precommit task passes successfully, focusing on critical correctness issues while treating style preferences as advisory.

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for details on the function grouping trade-offs in large LiveView modules.
See [CREDO_FIXES_SUMMARY.md](CREDO_FIXES_SUMMARY.md) for details on how all Credo issues were resolved.
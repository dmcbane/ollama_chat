# Code Quality Checklist

Quick reference for maintaining code quality in Ollama Chat.

## Before Every Commit

```bash
mix precommit
```

This single command runs all quality checks:
- ✅ Compile with warnings as errors
- ✅ Check unused dependencies
- ✅ Verify code formatting
- ✅ Run Credo static analysis
- ✅ Run Dialyzer type checking
- ✅ Run full test suite

## Individual Commands

### Compilation
```bash
# Check for warnings
mix compile --warnings-as-errors
```

### Formatting
```bash
# Check if code is formatted
mix format --check-formatted

# Auto-format all code
mix format
```

### Static Analysis (Credo)
```bash
# Run with strict mode
mix credo --strict

# List all issues
mix credo list

# Explain specific issue
mix credo explain lib/path/to/file.ex:LINE
```

### Type Checking (Dialyzer)
```bash
# First time or after dependency changes
mix dialyzer --plt

# Run type checking
mix dialyzer
```

### Testing
```bash
# All tests
mix test

# Specific file
mix test test/path/to/test.exs

# Re-run failed tests
mix test --failed

# With coverage
mix test --cover
```

## Quick Fixes

### Format All Code
```bash
mix format
```

### Fix Unused Dependencies
```bash
mix deps.unlock --unused
```

### Rebuild Dialyzer PLT
```bash
rm -rf priv/plts/*.plt*
mix dialyzer --plt
```

### Clean Build
```bash
mix clean
mix compile
```

## Current Status

- **Tests**: 196/196 passing (100%)
- **Dialyzer**: 0 errors
- **Credo**: 3 low-priority issues
- **Coverage**: All critical paths tested

## Common Issues

### Compiler Warning: Ungrouped Functions
Functions with same name/arity must be grouped together.

**Fix**: Move all clauses for `def function_name/arity` together in file.

### Dialyzer: Unmatched Return
When a function's return value is ignored.

**Fix**: Assign to `_variable` to show it's intentionally ignored:
```elixir
_ref = Process.send_after(self(), :msg, 1000)
```

### Credo: Nesting Too Deep
Function body nested deeper than 3 levels.

**Fix**: Extract nested logic into separate functions or use `with`.

## Documentation

See [CODE_QUALITY.md](CODE_QUALITY.md) for detailed information about:
- Tool configuration
- Type specifications
- Error handling guidelines
- Testing patterns
- Code style guidelines
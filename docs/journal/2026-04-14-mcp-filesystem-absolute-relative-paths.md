# Dev Journal — MCP Filesystem: Absolute and Relative Path Support

**Date:** 2026-04-14  
**Files changed:** `mcp_test_server/lib/mcp_test_server/servers/filesystem.ex`, `mcp_test_server/lib/mcp_test_server/application.ex`, `mcp_test_server/mcpctl`  
**Session context:** User reported filesystem MCP server not working. Investigation revealed two issues: workspace path not configured, and only relative paths supported.

---

## Problem Statement

The filesystem MCP server had two critical limitations:

### Issue 1: Workspace Path Ignored
The `root_path` from MCP client configuration was being passed but not read by the server, causing all file operations to fail with `:enoent` errors.

**Root cause:**
- MCP client correctly passed `root_path="/Users/mcbaneh/devel"` as command-line argument
- `mcpctl` script didn't forward extra arguments to `mix run`
- `Application.start/2` didn't read `System.argv()` to configure workspace
- Server always used default `/tmp/mcp_workspace`

### Issue 2: Relative Paths Only
The server only accepted paths relative to the workspace root. LLMs would naturally use absolute paths, requiring manual conversion:

```elixir
# What LLMs want to do:
list_directory("/Users/mcbaneh/devel/ollama_chat")

# What they had to do instead:
list_directory("ollama_chat")
```

This made the tools harder to use and less intuitive for LLMs.

---

## Solution

### Part 1: Workspace Configuration (Commit `738bdb3`)

**mcpctl script:**
```bash
# Before:
exec env MCP_SERVER="$SERVER" mix run --no-halt

# After:
SERVER="${COMMAND:-filesystem}"
shift  # Remove server name from arguments
exec env MCP_SERVER="$SERVER" mix run --no-halt -- "$@"
```

**Application.start/2:**
```elixir
defp configure_workspace_from_argv do
  case System.argv() do
    [workspace_path | _] when is_binary(workspace_path) and workspace_path != "" ->
      expanded = Path.expand(workspace_path)
      if File.dir?(expanded) do
        Application.put_env(:mcp_test_server, :workspace_path, expanded)
        IO.puts(:stderr, "MCP Filesystem workspace: #{expanded}")
      end
    _ ->
      :ok
  end
end
```

### Part 2: Absolute Path Support (Commit `243ed9b`)

Added `resolve_path/2` helper function:

```elixir
defp resolve_path(path, workspace) do
  full_path =
    if Path.type(path) == :absolute do
      # Absolute path: use it directly
      path
    else
      # Relative path: join with workspace
      Path.join(workspace, path)
    end

  # Expand to resolve any . or .. segments
  real_path = Path.expand(full_path)
  real_workspace = Path.expand(workspace)
  real_workspace = Path.join(real_workspace, "")

  if String.starts_with?(real_path, real_workspace) or 
     real_path == String.trim_trailing(real_workspace, "/") do
    {:ok, real_path}
  else
    {:error, "Access denied: path outside workspace"}
  end
end
```

**Updated handlers** to use `resolve_path/2`:
- `read_file`, `write_file`, `list_directory`
- `file_info`, `create_directory`
- `move_file`, `copy_file` (resolve both source and destination)
- `delete_file`, `delete_directory`

---

## Path Resolution Examples

| Input Path | Workspace | Result |
|------------|-----------|---------|
| `"ollama_chat/README.md"` | `/Users/foo/devel` | ✅ `/Users/foo/devel/ollama_chat/README.md` |
| `"."` | `/Users/foo/devel` | ✅ `/Users/foo/devel` |
| `""` | `/Users/foo/devel` | ✅ `/Users/foo/devel` |
| `"/Users/foo/devel/ollama_chat/README.md"` | `/Users/foo/devel` | ✅ `/Users/foo/devel/ollama_chat/README.md` |
| `"/Users/foo/devel"` | `/Users/foo/devel` | ✅ `/Users/foo/devel` (workspace root) |
| `"/etc/passwd"` | `/Users/foo/devel` | ❌ Access denied: outside workspace |
| `"/Users/foo/other"` | `/Users/foo/devel` | ❌ Access denied: outside workspace |
| `"../../../etc/passwd"` | `/Users/foo/devel` | ❌ Access denied: path traversal blocked |

---

## Testing

### Manual Testing

Created `test_path_resolution.exs` with 8 test cases covering:
- Relative paths
- Absolute paths within workspace
- Absolute paths outside workspace
- Path traversal attempts

**Results:** All 8 tests passed ✓

### Integration Testing

**Test 1: Workspace configuration**
```bash
$ elixir test_workspace.exs /Users/mcbaneh/devel
Workspace argument: /Users/mcbaneh/devel
Expanded path: /Users/mcbaneh/devel
Directory exists: true
Configured workspace: /Users/mcbaneh/devel
```

**Test 2: Path resolution**
```bash
$ elixir test_path_resolution.exs
Testing path resolution with workspace: /Users/mcbaneh/devel

✓ PASS | "ollama_chat/README.md"
✓ PASS | "."
✓ PASS | ""
✓ PASS | "/Users/mcbaneh/devel/ollama_chat/README.md"
✓ PASS | "/Users/mcbaneh/devel"
✓ PASS | "/etc/passwd"
✓ PASS | "/Users/mcbaneh/other"
✓ PASS | "../../../etc/passwd"
```

---

## Key Takeaways

**On MCP server command-line arguments:**
- Use `shift` in bash to remove the server name before passing args through
- Use `-- "$@"` in `mix run` to separate Mix options from application arguments
- Read `System.argv()` in `Application.start/2` to access passed arguments
- Validate and configure before starting supervised processes

**On path resolution in sandboxed filesystem tools:**
- Support both absolute and relative paths for better UX
- Always expand paths to resolve `.` and `..` segments
- Validate final path against workspace boundary
- Use `Path.type/1` to detect absolute vs relative paths
- Add trailing `/` to workspace for proper prefix checking

**On security validation:**
- Path expansion must happen before validation
- Check both exact match and prefix match for workspace root
- Block paths that resolve outside the workspace
- Never trust user-provided paths without validation

**On debugging path issues:**
- Log the configured workspace to stderr for visibility
- Include both input path and resolved path in error messages
- Test with edge cases: empty string, ".", absolute paths, traversal attempts

---

## User Impact

**Before:**
- LLM asks: "List files in /Users/mcbaneh/devel/ollama_chat"
- Response: `:enoent` error

**After:**
- LLM asks: "List files in /Users/mcbaneh/devel/ollama_chat"
- Response: ✅ File list returned successfully

LLMs can now use natural absolute paths without conversion, making filesystem tools significantly more usable.

---

## Commits

1. **`738bdb3`** — fix(mcp): filesystem server now respects root_path from MCP client
2. **`243ed9b`** — feat(mcp): filesystem server now accepts both absolute and relative paths

Both pushed to `origin/main` ✓

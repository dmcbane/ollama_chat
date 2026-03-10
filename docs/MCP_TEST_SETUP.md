# MCP Test Server Setup

This document describes how to set up MCP (Model Context Protocol) test servers for local development and testing.

## Prerequisites

- **Node.js 18+** - Required for running MCP servers
- **npm/npx** - Comes with Node.js
- **Elixir 1.15+** - For running the Phoenix application
- **Mix dependencies** - Run `mix deps.get`

## Quick Setup

Run the automated setup script:

```bash
./scripts/setup_mcp_servers.sh
```

This script will:
1. Verify Node.js and npm are installed
2. Create the MCP workspace directory (`tmp/mcp_workspace`)
3. Create test files for development
4. Verify MCP servers are available via npx

## Available Test Servers

### 1. Filesystem Server

**Package**: `@modelcontextprotocol/server-filesystem`

**Purpose**: Read and write files in a specified directory

**Tools Provided**:
- `read_file` - Read file contents
- `read_multiple_files` - Read multiple files at once
- `write_file` - Write content to a file
- `create_directory` - Create a new directory
- `list_directory` - List directory contents
- `move_file` - Move or rename a file
- `search_files` - Search for files by pattern
- `get_file_info` - Get file metadata

**Configuration**:
```elixir
%{
  name: :filesystem,
  display_name: "File System",
  description: "Read and write files",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", 
         Path.expand("./tmp/mcp_workspace")],
  enabled: true,
  requires_approval: true,
  dangerous_tools: ["write_file", "create_directory", "move_file"]
}
```

**Testing Manually**:
```bash
# Start the server manually to test
npx -y @modelcontextprotocol/server-filesystem ./tmp/mcp_workspace

# Or test with a simple client
echo '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}' | \
  npx -y @modelcontextprotocol/server-filesystem ./tmp/mcp_workspace
```

### 2. Time Server

**Package**: `@modelcontextprotocol/server-time`

**Purpose**: Provide current time and timezone information

**Tools Provided**:
- `get_current_time` - Get current time in specified format/timezone
- `convert_time` - Convert time between timezones
- `get_timestamp` - Get Unix timestamp

**Configuration**:
```elixir
%{
  name: :time,
  display_name: "Time",
  description: "Time and timezone operations",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-time"],
  enabled: true,
  requires_approval: false
}
```

**Testing Manually**:
```bash
# Start the time server
npx -y @modelcontextprotocol/server-time
```

## Development Workflow

### 1. Start MCP Servers Automatically

MCP servers are started automatically by the Phoenix application when configured in `config/dev.exs`.

Start the Phoenix server:
```bash
mix phx.server
```

The logs will show:
```
[info] Starting MCP client manager
[info] Started MCP server: File System
[info] Started MCP server: Time
[info] Discovered 11 MCP tools
```

### 2. Verify MCP Integration

Check the MCP tools are loaded:

```elixir
# In IEx console
iex> {:ok, tools} = OllamaChat.MCPClient.list_tools()
iex> Map.keys(tools)
["read_file", "write_file", "list_directory", "get_current_time", ...]
```

### 3. Test Tool Execution

```elixir
# Read a test file
iex> OllamaChat.MCPClient.call_tool("read_file", %{"path" => "test.txt"})
{:ok, [%{"type" => "text", "text" => "Hello from MCP test workspace!"}]}

# Get current time
iex> OllamaChat.MCPClient.call_tool("get_current_time", %{"timezone" => "UTC"})
{:ok, [%{"type" => "text", "text" => "2026-02-27T18:30:00Z"}]}

# List directory
iex> OllamaChat.MCPClient.call_tool("list_directory", %{"path" => "."})
{:ok, [%{"type" => "text", "text" => "test.txt\ntest.md\ntest.json"}]}
```

## Test Files

The setup script creates these test files in `tmp/mcp_workspace`:

- **test.txt** - Plain text file
- **test.md** - Markdown file
- **test.json** - JSON file

You can add more test files as needed:

```bash
# Create additional test files
echo "Hello World" > tmp/mcp_workspace/hello.txt
echo "# Documentation" > tmp/mcp_workspace/docs.md
mkdir tmp/mcp_workspace/subdir
```

## Testing MCP in the UI

### 1. Check MCP Panel

1. Start the server: `mix phx.server`
2. Navigate to `http://localhost:4000`
3. Look for the "MCP Tools" section in the sidebar
4. Click to expand and verify tools are listed

### 2. Test Tool Calls

Try these prompts:

**Filesystem Tools**:
- "Read the contents of test.txt"
- "List all files in the current directory"
- "Show me the contents of test.json"

**Time Tools**:
- "What time is it?"
- "What's the current time in Tokyo?"
- "Give me the Unix timestamp"

### 3. Test Approval Workflow

Try a dangerous operation:
- "Create a new file called output.txt with the text 'Hello'"
- An approval modal should appear
- Click "Approve" or "Deny"

## Configuration

### Development Configuration

**File**: `config/dev.exs`

```elixir
config :ollama_chat, :mcp_enabled, true

config :ollama_chat, :mcp_servers, [
  %{
    name: :filesystem,
    display_name: "File System (Dev)",
    description: "Read and write files in test workspace",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", 
           Path.expand("./tmp/mcp_workspace")],
    enabled: true,
    requires_approval: false,  # Auto-approve in dev
    dangerous_tools: ["write_file", "create_directory", "move_file", "delete_file"]
  },
  %{
    name: :time,
    display_name: "Time",
    description: "Time and timezone operations",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-time"],
    enabled: true,
    requires_approval: false
  }
]
```

### Test Configuration

**File**: `config/test.exs`

```elixir
# Disable MCP by default in tests
config :ollama_chat, :mcp_enabled, false
config :ollama_chat, :mcp_servers, []
```

Enable for specific tests:
```elixir
@tag :mcp_integration
test "uses MCP tools" do
  # Test will run with MCP enabled
end
```

## Troubleshooting

### MCP Servers Not Starting

**Symptom**: Error logs showing "Failed to start MCP server"

**Solutions**:
1. Verify Node.js is installed: `node --version`
2. Test npx manually: `npx -y @modelcontextprotocol/server-filesystem --help`
3. Check server command is correct in config
4. Ensure workspace directory exists and is readable

### Tools Not Discovered

**Symptom**: `list_tools()` returns empty map

**Solutions**:
1. Check MCP is enabled: `Application.get_env(:ollama_chat, :mcp_enabled)`
2. Verify servers started: Check logs for "Started MCP server"
3. Wait for discovery: Tools are discovered 1 second after startup
4. Force refresh: `OllamaChat.MCPClient.refresh_tools()`

### Tool Execution Fails

**Symptom**: `call_tool` returns error

**Solutions**:
1. Verify tool exists: `OllamaChat.MCPClient.list_tools()`
2. Check arguments match schema
3. Test server manually with npx
4. Check file permissions for filesystem operations
5. Verify paths are within workspace directory

### npx Takes Too Long

**Symptom**: First tool call is slow

**Explanation**: npx downloads packages on first use

**Solutions**:
1. Pre-install packages:
   ```bash
   npm install -g @modelcontextprotocol/server-filesystem
   npm install -g @modelcontextprotocol/server-time
   ```
2. Use local installation instead of npx
3. Wait for initial download (only happens once)

### Permission Denied Errors

**Symptom**: "EACCES: permission denied"

**Solutions**:
1. Check workspace directory permissions:
   ```bash
   chmod 755 tmp/mcp_workspace
   ```
2. Verify user has write access
3. Check if directory is on a restricted filesystem

## Running Tests

### Unit Tests

```bash
# Run MCP-specific tests
mix test --only mcp

# Run specific test file
mix test test/ollama_chat/mcp_client_test.exs
```

### Integration Tests

```bash
# Ensure servers are available first
./scripts/setup_mcp_servers.sh

# Run integration tests
mix test --only mcp_integration
```

### Performance Tests

```bash
mix test --only performance
```

## Adding New Test Servers

To add a new MCP server for testing:

1. **Find an MCP server package**:
   - Check https://github.com/modelcontextprotocol/servers
   - Or search npm for "mcp-server-*"

2. **Add to configuration**:
   ```elixir
   %{
     name: :my_server,
     display_name: "My Server",
     description: "Does something useful",
     command: "npx",
     args: ["-y", "@my-org/mcp-server-package"],
     enabled: true,
     requires_approval: true
   }
   ```

3. **Restart Phoenix server**:
   ```bash
   mix phx.server
   ```

4. **Verify tools are discovered**:
   ```elixir
   {:ok, tools} = OllamaChat.MCPClient.list_tools()
   ```

## Best Practices

### Development

- ✅ Use `tmp/mcp_workspace` for testing (gitignored)
- ✅ Disable approval in dev config for faster testing
- ✅ Add test files covering different scenarios
- ✅ Test error cases (missing files, invalid paths)
- ✅ Monitor logs for MCP-related errors

### Testing

- ✅ Use `@tag :mcp_integration` for tests requiring servers
- ✅ Mock MCP client for unit tests
- ✅ Test both success and error paths
- ✅ Verify approval workflow
- ✅ Test timeout scenarios

### Security

- ⚠️ Never point filesystem server at sensitive directories
- ⚠️ Always require approval for write operations in production
- ⚠️ Restrict paths to known-safe locations
- ⚠️ Validate all tool arguments
- ⚠️ Log all tool executions

## Next Steps

Once MCP test servers are set up:

1. ✅ Verify setup is working
2. 📋 Begin Phase 1 implementation (MCPClient module)
3. 📋 Test tool discovery
4. 📋 Test tool execution
5. 📋 Move to Phase 2 (Ollama integration)

## Resources

- **MCP Specification**: https://spec.modelcontextprotocol.io/
- **MCP Servers**: https://github.com/modelcontextprotocol/servers
- **Filesystem Server**: https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem
- **Time Server**: https://github.com/modelcontextprotocol/servers/tree/main/src/time
- **ex_mcp Docs**: https://github.com/azmaveth/ex_mcp
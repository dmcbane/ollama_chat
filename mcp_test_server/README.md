# MCP Test Server

A comprehensive Elixir-based Model Context Protocol (MCP) server for testing and development. This server implements multiple tool categories similar to the official MCP reference servers, but built entirely on the Elixir/BEAM platform.

> **Note:** This MCP server communicates via **stdio** (standard input/output), not HTTP. It does not use any network ports and cannot conflict with other services like the Ollama Chat Phoenix server (which runs on port 4000 by default).

## Features

### 🗂️ Filesystem Tools (Full npm parity + extras!)
- **read_file** - Read file contents from the workspace
- **write_file** - Write content to files in the workspace
- **list_directory** - List directory contents with detailed information
- **file_info** - Get detailed file/directory metadata (size, permissions, dates)
- **create_directory** - Create new directories
- **move_file** - Move or rename files and directories
- **copy_file** - Copy files to new locations
- **delete_file** - Delete individual files
- **delete_directory** - Delete directories and all contents recursively
- **search_files** - Search for files by name pattern (supports wildcards)
- **get_file_size** - Get file size in human-readable format

### 💾 Memory/KV Store Tools
- **memory_set** - Store key-value pairs with optional TTL (time-to-live)
- **memory_get** - Retrieve stored values by key
- **memory_delete** - Delete stored key-value pairs
- **memory_list** - List all currently stored keys

### 🔧 Utility Tools
- **echo** - Echo back provided text (useful for testing)
- **get_time** - Get current server time with timezone support
- **random_number** - Generate random numbers within a specified range
- **hash_text** - Generate cryptographic hashes (MD5, SHA256, SHA512)

## Architecture

Built on Elixir/OTP with:
- **GenServer** for state management
- **Supervision trees** for fault tolerance
- **ExMCP** library for MCP protocol implementation
- **In-memory ETS-like storage** for the KV store with automatic TTL cleanup

## Installation

### Prerequisites

- Elixir 1.14 or later
- Erlang/OTP 24 or later

### Setup

1. Navigate to the project directory:
```bash
cd mcp_test_server
```

2. Install dependencies:
```bash
mix deps.get
```

3. Compile the project:
```bash
mix compile
```

## Usage

### Starting the Server

#### Using the Start Script (Recommended)

```bash
./start.sh
```

The script will:
- Check for Elixir installation
- Install dependencies if needed
- Create the workspace directory
- Compile and start the server

#### Manual Start

```bash
# Set workspace path (optional)
export MCP_WORKSPACE=/path/to/workspace

# Start the server
mix run --no-halt
```

### Configuration

#### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_WORKSPACE` | Workspace directory for filesystem operations | `../tmp/mcp_workspace` |

> **Note:** The MCP test server does not use `OLLAMA_CHAT_PORT` or any HTTP port configuration, as it communicates via stdio transport.

#### Protocol Version

The MCP test server implements **MCP protocol version 2024-11-05**, which is compatible with:
- ExMCP 0.8.x and newer
- Official npm MCP servers (2024-11-05 and later)

If you encounter handshake errors like "Failed to parse handshake response: invalid message format", ensure the protocol versions are compatible.

#### Workspace Path

The workspace path can be configured in three ways (in order of precedence):

1. **Environment variable**:
```bash
export MCP_WORKSPACE=/path/to/workspace
./start.sh
```

2. **Config file** (`config/dev.exs`):
```elixir
config :mcp_test_server,
  workspace_path: "/path/to/workspace"
```

3. **Default**: `../tmp/mcp_workspace` (created automatically)

## Integration with Ollama Chat

To use this server with the Ollama Chat application:

**Important:** The Ollama Chat Phoenix server (default port 4000, configurable via `OLLAMA_CHAT_PORT`) and the MCP test server do not conflict, as the MCP server uses stdio communication, not HTTP ports.

### Why Use This Instead of npm Servers?

✅ **No Node.js dependency** - Pure Elixir, works anywhere Elixir runs
✅ **More filesystem operations** - Includes copy, delete, search extras
✅ **Memory + utilities built-in** - 19 tools in one server vs multiple npm packages
✅ **Better performance** - BEAM VM efficiency, fast startup
✅ **Simpler deployment** - No npm, no node_modules, no package.json

1. **Configure Ollama Chat** (`config/dev.exs`):
```elixir
config :ollama_chat, :mcp_servers, [
  %{
    name: :test_server,
    display_name: "Elixir Test Server",
    command: "elixir",
    args: ["-S", "mix", "run", "--no-halt"],
    working_dir: "/absolute/path/to/mcp_test_server",
    env: %{
      "MCP_WORKSPACE" => "/absolute/path/to/workspace"
    },
    requires_approval: false
  }
]
```

2. **Restart Ollama Chat** to load the new server configuration. The MCP server will be automatically started by Ollama Chat when needed.

## Tool Examples

### Filesystem Operations

**Read a file**:
```json
{
  "tool": "read_file",
  "args": {
    "path": "hello.txt"
  }
}
```

**Write to a file**:
```json
{
  "tool": "write_file",
  "args": {
    "path": "output.txt",
    "content": "Hello from MCP!"
  }
}
```

**List directory**:
```json
{
  "tool": "list_directory",
  "args": {
    "path": "."
  }
}
```

**Create directory**:
```json
{
  "tool": "create_directory",
  "args": {
    "path": "new_folder"
  }
}
```

**Copy file**:
```json
{
  "tool": "copy_file",
  "args": {
    "source": "original.txt",
    "destination": "backup.txt"
  }
}
```

**Move/rename file**:
```json
{
  "tool": "move_file",
  "args": {
    "source": "old_name.txt",
    "destination": "new_name.txt"
  }
}
```

**Delete file**:
```json
{
  "tool": "delete_file",
  "args": {
    "path": "unwanted.txt"
  }
}
```

**Delete directory**:
```json
{
  "tool": "delete_directory",
  "args": {
    "path": "old_folder"
  }
}
```

**Search files**:
```json
{
  "tool": "search_files",
  "args": {
    "pattern": "*.txt",
    "path": "documents"
  }
}
```

**Get file size**:
```json
{
  "tool": "get_file_size",
  "args": {
    "path": "large_file.bin"
  }
}
```

### Memory Operations

**Store a value**:
```json
{
  "tool": "memory_set",
  "args": {
    "key": "user_name",
    "value": "Alice",
    "ttl": 3600
  }
}
```

**Retrieve a value**:
```json
{
  "tool": "memory_get",
  "args": {
    "key": "user_name"
  }
}
```

**List all keys**:
```json
{
  "tool": "memory_list",
  "args": {}
}
```

### Utility Operations

**Echo text**:
```json
{
  "tool": "echo",
  "args": {
    "text": "Hello, MCP!"
  }
}
```

**Get current time**:
```json
{
  "tool": "get_time",
  "args": {
    "timezone": "UTC"
  }
}
```

**Generate random number**:
```json
{
  "tool": "random_number",
  "args": {
    "min": 1,
    "max": 100
  }
}
```

**Hash text**:
```json
{
  "tool": "hash_text",
  "args": {
    "text": "secret message",
    "algorithm": "sha256"
  }
}
```

## Security Features

### Path Validation
All filesystem operations validate that paths remain within the configured workspace:
- Prevents directory traversal attacks (`../` attacks)
- Uses `Path.expand/1` for canonical path resolution
- Rejects operations outside the workspace boundary

### Memory Store
- In-memory only (no persistence to disk)
- Optional TTL for automatic expiration
- Background cleanup of expired entries every 60 seconds

## Development

### Running Tests

```bash
mix test
```

### Code Quality

```bash
# Format code
mix format

# Run static analysis
mix credo --strict

# Run type checking
mix dialyzer
```

### Interactive Console

```bash
iex -S mix
```

Example commands in IEx:
```elixir
# Check server info
McpTestServer.info()

# Manually test memory store
McpTestServer.MemoryStore.set("test_key", "test_value")
McpTestServer.MemoryStore.get("test_key")
McpTestServer.MemoryStore.list_keys()
```

## Project Structure

```
mcp_test_server/
├── config/
│   ├── config.exs          # Main configuration
│   ├── dev.exs             # Development config
│   ├── prod.exs            # Production config
│   └── test.exs            # Test config
├── lib/
│   └── mcp_test_server/
│       ├── application.ex  # OTP application
│       ├── memory_store.ex # In-memory KV store
│       └── server.ex       # Main MCP server with tools
├── mix.exs                 # Project dependencies
├── start.sh                # Start script
└── README.md               # This file
```

## Comparison with Reference Servers

This server **exceeds** the capabilities of the official npm MCP servers:

| Feature | npm server-filesystem | This Server |
|---------|----------------------|-------------|
| read_file | ✅ | ✅ |
| write_file | ✅ | ✅ |
| list_directory | ✅ | ✅ |
| file_info | ✅ | ✅ |
| create_directory | ✅ | ✅ |
| move_file | ✅ | ✅ |
| copy_file | ❌ | ✅ **Extra!** |
| delete_file | ❌ | ✅ **Extra!** |
| delete_directory | ❌ | ✅ **Extra!** |
| search_files | ✅ | ✅ |
| get_file_size | ❌ | ✅ **Extra!** |
| **Requires Node.js** | ✅ Yes | ❌ **No!** |

### Additional Capabilities

| Feature | Reference Server | This Server |
|---------|-----------------|-------------|
| Memory/KV store | `server-memory` | ✅ Implemented |
| Time utilities | `server-time` | ✅ Implemented |
| Random generation | Custom | ✅ Implemented |
| Hashing | Custom | ✅ Implemented |
| Platform | Node.js/TypeScript | Elixir/BEAM |
| **Total Tools** | ~4-6 per server | **19 tools** |

## Advantages of Elixir Implementation

- **No Node.js Required**: Pure Elixir - no npm, no Node.js installation needed
- **More Features**: Includes copy_file, delete_file, delete_directory, get_file_size
- **Fault Tolerance**: OTP supervision trees ensure reliability
- **Concurrency**: BEAM handles concurrent tool calls efficiently
- **Hot Code Reloading**: Update server code without stopping
- **Low Latency**: Native compiled code with fast startup
- **Resource Efficiency**: Lightweight processes with isolated state
- **Pattern Matching**: Clean, readable tool handler code
- **Single Binary**: Can be compiled to standalone executable

## Troubleshooting

### Server Won't Start

**Issue**: `mix: command not found`
**Solution**: Install Elixir - https://elixir-lang.org/install.html

**Issue**: `deps not found`
**Solution**: Run `mix deps.get` to install dependencies

**Issue**: `workspace permission denied`
**Solution**: Ensure the workspace directory is writable:
```bash
chmod 755 /path/to/workspace
```

### Tool Execution Errors

**Issue**: `Access denied: path outside workspace`
**Solution**: All filesystem operations must be within the configured workspace. Check your paths.

**Issue**: `Key not found`
**Solution**: The requested key doesn't exist or has expired (check TTL).

### Connection Issues

**Issue:** Ollama Chat can't connect
**Solution:** 
1. Verify server is running: `ps aux | grep mcp_test_server`
2. Check working_dir is absolute path in config
3. Restart Ollama Chat after config changes

### Protocol Handshake Errors

**Issue:** `Failed to parse handshake response: invalid message format`
**Solution:**
1. Ensure MCP test server is using protocol version `2024-11-05` or newer
2. Check that ExMCP library is version 0.8.0 or newer
3. Verify the server responds with proper JSON-RPC 2.0 format
4. Test server manually:
   ```bash
   echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}},"id":1}' | elixir -S mix run --no-halt
   ```
   Expected response should include `"protocolVersion":"2024-11-05"`

## Future Enhancements

- [ ] Add persistence layer (optional ETS/Mnesia storage)
- [ ] Implement resource templates
- [ ] Add streaming support for large file operations
- [ ] Network tools (HTTP requests, DNS lookups)
- [ ] System information tools
- [ ] Database connection tools
- [ ] Add comprehensive test suite
- [ ] Performance benchmarks

## License

This MCP test server is provided as part of the Ollama Chat project for testing and development purposes.

## Contributing

Contributions are welcome! Areas for improvement:
- Additional tool implementations
- Performance optimizations
- Better error handling
- More comprehensive tests
- Documentation improvements

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review the Ollama Chat MCP documentation
3. Examine server logs for error details

## Version

Current version: 0.1.0

## Changelog

### 0.2.0 (2024-12-19)
- **NEW:** Full npm @modelcontextprotocol/server-filesystem parity
- **NEW:** Additional tools: copy_file, delete_file, delete_directory, get_file_size
- **NEW:** search_files with wildcard pattern support
- **NEW:** create_directory for directory creation
- **NEW:** move_file for moving/renaming files and directories
- Total: 19 MCP tools (11 filesystem, 4 memory, 4 utility)
- **No Node.js required!** Pure Elixir implementation

### 0.1.0 (2024-02-27)
- Initial release
- Filesystem tools (read, write, list, info)
- Memory/KV store with TTL support
- Utility tools (echo, time, random, hash)
- Security: workspace path validation
- Background cleanup of expired entries
- Protocol version: 2024-11-05 for ExMCP 0.8.x compatibility
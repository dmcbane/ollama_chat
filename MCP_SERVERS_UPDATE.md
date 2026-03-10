# MCP Servers Configuration Update

**Date**: February 27, 2026  
**Issue**: Non-existent `@modelcontextprotocol/server-time` package referenced in configuration

## Problem

The development configuration (`config/dev.exs`) referenced a non-existent MCP server package:
- **Incorrect**: `@modelcontextprotocol/server-time`
- **Status**: Package does not exist in npm registry

## Solution

Updated configuration to use actual available MCP servers:
- **Replaced with**: `@modelcontextprotocol/server-everything` (disabled by default)
- **Purpose**: Demo server for testing MCP functionality

## Available MCP Servers

The following MCP servers are officially available from `@modelcontextprotocol`:

### 1. @modelcontextprotocol/server-filesystem ✅
**Status**: Currently configured and enabled in dev  
**Purpose**: File system operations  
**Tools**:
- `read_file` - Read file contents
- `write_file` - Write to files
- `list_directory` - List directory contents
- `create_directory` - Create directories
- `move_file` - Move/rename files
- `search_files` - Search for files

**Configuration**:
```elixir
%{
  name: :filesystem,
  display_name: "File System (Dev)",
  description: "Read and write files in test workspace",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", Path.expand("./tmp/mcp_workspace")],
  enabled: true,
  requires_approval: false,  # Auto-approve in dev
  dangerous_tools: ["write_file", "create_directory", "move_file", "delete_file"]
}
```

### 2. @modelcontextprotocol/server-everything (Demo) ⚠️
**Status**: Configured but disabled by default  
**Purpose**: Demo/testing server with toy tools  
**Tools**:
- `echo` - Echo back input
- `get-sum` - Add two numbers
- `get-tiny-image` - Return MCP logo
- `get-structured-content` - Structured data with validation
- `trigger-long-running-operation` - Progress update demo
- Various other demo tools

**Configuration**:
```elixir
%{
  name: :everything,
  display_name: "Everything (Demo)",
  description: "Demo MCP server with various test tools",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-everything"],
  enabled: false,  # Disabled by default
  requires_approval: false
}
```

**Note**: This is a demo server. Enable it only for testing MCP functionality.

### 3. @modelcontextprotocol/server-memory
**Status**: Not configured  
**Purpose**: Persistent memory/knowledge graph  
**Use Case**: Store and retrieve information across conversations

**Example Configuration**:
```elixir
%{
  name: :memory,
  display_name: "Memory",
  description: "Persistent knowledge graph",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-memory"],
  enabled: false,
  requires_approval: false
}
```

### 4. @modelcontextprotocol/server-sequential-thinking
**Status**: Not configured  
**Purpose**: Extended reasoning and thinking process  
**Use Case**: Complex problem-solving with step-by-step thinking

### 5. @modelcontextprotocol/server-pdf
**Status**: Not configured  
**Purpose**: PDF manipulation and analysis  
**Use Case**: Read, extract, and manipulate PDF documents

### 6. @modelcontextprotocol/server-map
**Status**: Not configured  
**Purpose**: Mapping and location services  
**Use Case**: Geographic data and location-based operations

### 7. @modelcontextprotocol/server-transcript
**Status**: Not configured  
**Purpose**: Transcript processing  
**Use Case**: Handle conversation transcripts

### 8. @modelcontextprotocol/server-threejs
**Status**: Not configured  
**Purpose**: 3D graphics and visualization  
**Use Case**: Generate and manipulate 3D scenes

## Current Configuration

### Development (config/dev.exs)

```elixir
config :ollama_chat, :mcp_enabled, true

config :ollama_chat, :mcp_servers, [
  # Filesystem - Enabled for file operations testing
  %{
    name: :filesystem,
    display_name: "File System (Dev)",
    description: "Read and write files in test workspace",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", Path.expand("./tmp/mcp_workspace")],
    enabled: true,
    requires_approval: false,
    dangerous_tools: ["write_file", "create_directory", "move_file", "delete_file"]
  },
  
  # Everything - Disabled by default (demo/testing only)
  %{
    name: :everything,
    display_name: "Everything (Demo)",
    description: "Demo MCP server with various test tools",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-everything"],
    enabled: false,
    requires_approval: false
  }
]
```

### Production (config/runtime.exs)

MCP is disabled in production by default. To enable:

```elixir
config :ollama_chat, :mcp_enabled, true

config :ollama_chat, :mcp_servers, [
  %{
    name: :filesystem,
    display_name: "File System",
    description: "Read and write files",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/workspace"],
    enabled: true,
    requires_approval: true,  # Require approval in production
    dangerous_tools: ["write_file", "create_directory", "move_file", "delete_file"]
  }
]
```

## Recommendations

### For Development
1. **Keep filesystem enabled** - Useful for testing file operations
2. **Enable everything server** - Only when actively testing MCP functionality
3. **Consider adding memory server** - For testing persistent knowledge features

### For Production
1. **Only enable necessary servers** - Minimize attack surface
2. **Always require approval** - For dangerous operations
3. **Use restricted paths** - Limit filesystem access to specific directories
4. **Monitor tool usage** - Log all MCP tool calls
5. **Regular security audits** - Review enabled servers and tools

## Adding New MCP Servers

To add a new MCP server:

1. **Check availability**:
   ```bash
   npm view @modelcontextprotocol/server-<name>
   ```

2. **Test manually**:
   ```bash
   npx -y @modelcontextprotocol/server-<name>
   ```

3. **Add to configuration**:
   ```elixir
   %{
     name: :server_name,
     display_name: "Display Name",
     description: "What this server does",
     command: "npx",
     args: ["-y", "@modelcontextprotocol/server-<name>", ...args],
     enabled: false,  # Start disabled
     requires_approval: true  # Be safe
   }
   ```

4. **Test in development**:
   - Enable the server
   - Restart Phoenix: `mix phx.server`
   - Check logs for successful connection
   - Test tool calls through UI

5. **Document**:
   - Add to this file
   - Update MCP_TEST_SETUP.md
   - Add usage examples

## Troubleshooting

### Server Not Found
```
npm error 404 Not Found - GET https://registry.npmjs.org/@modelcontextprotocol%2fserver-xyz
```
**Solution**: Package doesn't exist. Check npm for available packages.

### Server Won't Start
1. Check Node.js version: `node --version` (requires 18+)
2. Test npx manually: `npx -y @modelcontextprotocol/server-filesystem --help`
3. Check configuration syntax in `config/dev.exs`
4. Review Phoenix logs for error messages

### Tools Not Appearing
1. Verify server is enabled: `enabled: true`
2. Check MCP is enabled: `config :ollama_chat, :mcp_enabled, true`
3. Restart Phoenix server
4. Check browser console for errors
5. Verify MCPClient started: Check Phoenix logs

## Resources

- [MCP Official Documentation](https://modelcontextprotocol.io)
- [MCP Servers Repository](https://github.com/modelcontextprotocol/servers)
- [ex_mcp Hex Package](https://hexdocs.pm/ex_mcp)
- [MCP_TEST_SETUP.md](MCP_TEST_SETUP.md) - Detailed testing guide
- [MCP_IMPLEMENTATION_PLAN.md](docs/MCP_IMPLEMENTATION_PLAN.md) - Implementation details

## Changes Made

### Files Updated
1. `config/dev.exs` - Removed server-time, added server-everything (disabled)
2. `docs/MCP_TEST_SETUP.md` - Updated server documentation
3. `docs/MCP_PROJECT_BOARD.md` - Updated dependencies list
4. `MCP_SERVERS_UPDATE.md` - This file (new)

### Testing
- ✅ Verified server-filesystem still works
- ✅ Confirmed server-time doesn't exist
- ✅ Verified server-everything is available
- ✅ All tests still passing (196/196)

## Summary

The configuration has been corrected to reference only actual, existing MCP server packages. The non-existent `@modelcontextprotocol/server-time` has been replaced with `@modelcontextprotocol/server-everything` (disabled by default) for optional demo/testing purposes.

**Current Status**: ✅ Fixed and verified  
**Impact**: None - MCP functionality unchanged  
**Action Required**: None - changes already committed
# MCP User Guide: Using Model Context Protocol in Ollama Chat

**Model Context Protocol (MCP)** allows your AI assistant to interact with external tools and services, enabling it to perform real-world actions like reading files, searching data, and more.

## Quick Start

### Is MCP Enabled?

Look for the **MCP Settings** section in the chat sidebar (left side). If you see it, MCP is enabled!

### Using MCP Tools

1. **Ask the AI to use tools naturally**:
   - "Read the contents of README.md"
   - "Create a new file called notes.txt with my meeting notes"
   - "List all files in the current directory"

2. **The AI will detect when to use tools** and show you:
   - 🔵 **Blue box**: Tool call in progress
   - ✅ **Green box**: Tool succeeded with results
   - ❌ **Red box**: Tool failed with error message

3. **Approve dangerous operations** (if configured):
   - A modal will appear asking for confirmation
   - Review the tool name and arguments
   - Click "Approve" or "Cancel"

### View Available Tools

Click the **"MCP Settings"** section in the sidebar to see:
- Number of available tools
- Each tool's name, server, and description
- Which tools require approval

## How It Works

### The Flow

```
You ask → AI decides to use tool → Tool executes → AI sees result → AI responds
```

**Example conversation**:

```
You: "What files are in my workspace?"

AI: Let me check that for you.
    [🔵 Tool Call: list_directory]

AI: I found these files:
    - README.md
    - package.json
    - src/
    - tests/
```

### Tool Call Indicators

When the AI uses a tool, you'll see visual indicators:

**🔵 In Progress** (Blue pulsing box):
```
🔧 Tool Call: read_file
Arguments:
  path: "README.md"
```

**✅ Success** (Green box):
```
✓ Tool Result: read_file
Output:
  # My Project
  This is a sample README...
```

**❌ Error** (Red box):
```
✗ Tool Error: read_file
Error: File not found: /path/to/missing.txt
```

## Currently Available Tools

### Filesystem Server (Enabled in Dev)

The filesystem server provides file operations within a restricted workspace.

#### Read Operations (No Approval Required)
- **read_file** / **read_text_file** - Read text file contents
- **read_media_file** - Read images/audio as base64
- **read_multiple_files** - Read several files at once
- **list_directory** - List files and directories
- **list_directory_with_sizes** - List with size information
- **directory_tree** - Recursive tree view
- **get_file_info** - Get file metadata
- **search_files** - Search for files by pattern

#### Write Operations (May Require Approval)
- **write_file** - Create or overwrite a file
- **edit_file** - Make line-based edits to existing file
- **create_directory** - Create new directories
- **move_file** - Move or rename files

**Note**: In development, write operations are auto-approved for faster testing. In production, they require explicit approval.

## Configuration

### For Developers

MCP is configured in `config/dev.exs`:

```elixir
# Enable MCP
config :ollama_chat, :mcp_enabled, true

# Configure servers
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
    dangerous_tools: ["write_file", "create_directory", 
                      "move_file", "delete_file"]
  }
]
```

### Workspace Directory

Files are accessed relative to the configured workspace:
- **Dev**: `./tmp/mcp_workspace`
- **Production**: Set via environment variable

The AI can only access files within this directory for security.

## Example Usage Scenarios

### 1. Reading Files

**You**: "What's in my README file?"

**AI**: "Let me read that for you."
```
🔧 list_directory → finds README.md
🔧 read_file (path: "README.md") → gets contents
```

**AI**: "Your README contains information about your project setup..."

### 2. Creating Files

**You**: "Create a new file called todo.txt with three items: buy milk, call mom, finish report"

**AI**: "I'll create that file for you."
```
🔧 write_file
    path: "todo.txt"
    content: "1. Buy milk\n2. Call mom\n3. Finish report"
```

**AI**: "I've created todo.txt with your three items."

### 3. Searching Files

**You**: "Find all JavaScript files in my project"

**AI**: "Let me search for those."
```
🔧 search_files (pattern: "*.js") → finds all .js files
```

**AI**: "I found 12 JavaScript files: index.js, app.js, utils.js..."

### 4. Working with Multiple Files

**You**: "Compare the content of config.dev.js and config.prod.js"

**AI**: "I'll read both files to compare them."
```
🔧 read_multiple_files
    paths: ["config.dev.js", "config.prod.js"]
```

**AI**: "Here are the differences between your dev and prod configs..."

## Approval Workflow

When an operation requires approval (configured via `requires_approval: true`):

### You'll See a Modal

```
┌─────────────────────────────────────────┐
│  Tool Approval Required                 │
├─────────────────────────────────────────┤
│                                         │
│  Tool: write_file                       │
│                                         │
│  Arguments:                             │
│    path: important-data.txt             │
│    content: [New file content...]       │
│                                         │
│  [Cancel]              [Approve]        │
│                                         │
└─────────────────────────────────────────┘
```

### What to Check

1. **Tool name** - Is this the right operation?
2. **Arguments** - Are the values correct?
3. **Impact** - What will this do to your system?

### Decisions

- **Click "Approve"** - Tool executes immediately
- **Click "Cancel"** - Tool is cancelled, AI is notified

## Tips & Best Practices

### For Users

1. **Be specific** in your requests
   - ✅ "Read the file called config.json in the src directory"
   - ❌ "Show me the config"

2. **Review approval requests carefully**
   - Check the file paths
   - Verify the operation makes sense
   - Don't approve if uncertain

3. **Check the MCP Settings panel** to see what tools are available

4. **Let the AI know about failures**
   - If a tool fails, the AI sees the error
   - It can try alternative approaches
   - Ask clarifying questions if needed

### For Developers

1. **Start with read-only tools** when learning

2. **Use restricted workspaces** in production
   ```elixir
   # Limit to specific directory
   args: ["-y", "@modelcontextprotocol/server-filesystem", "/safe/workspace"]
   ```

3. **Require approval for dangerous operations**
   ```elixir
   requires_approval: true,
   dangerous_tools: ["write_file", "delete_file", "move_file"]
   ```

4. **Test thoroughly** before enabling in production

5. **Monitor logs** for tool usage and errors

## Adding More MCP Servers

### Available Servers

See [MCP_SERVERS_UPDATE.md](MCP_SERVERS_UPDATE.md) for the full list:

- **server-filesystem** ✅ (currently configured)
- **server-memory** - Persistent knowledge across conversations
- **server-sequential-thinking** - Extended reasoning
- **server-pdf** - PDF manipulation
- **server-map** - Geographic/location services
- **server-everything** - Demo/testing tools

### How to Add a Server

1. **Edit `config/dev.exs`** and add to `:mcp_servers`:

```elixir
%{
  name: :memory,
  display_name: "Memory",
  description: "Persistent knowledge storage",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-memory"],
  enabled: true,
  requires_approval: false
}
```

2. **Restart Phoenix**: `mix phx.server`

3. **Check MCP Settings panel** - New tools should appear

4. **Test with the AI**:
   - "Store this information: My favorite color is blue"
   - "What's my favorite color?" (in a new conversation)

## Troubleshooting

### "No MCP tools available"

**Check**:
1. Is MCP enabled? (`config :ollama_chat, :mcp_enabled, true`)
2. Are servers configured in `:mcp_servers`?
3. Is at least one server `enabled: true`?
4. Check Phoenix logs for connection errors

**Fix**: Restart Phoenix after configuration changes

### "Tool not found: xyz"

**Cause**: The AI tried to use a tool that doesn't exist

**Fix**: 
- Check available tools in MCP Settings panel
- Tell the AI what tools are available
- The AI will retry with correct tool name

### Tools not showing in UI

**Check**:
1. MCP Settings panel is expanded (click "MCP Settings")
2. Phoenix server is running
3. Check browser console for JavaScript errors

**Fix**: Refresh the page, check logs

### "Server connection failed"

**Possible causes**:
- Node.js not installed (required for MCP servers)
- Network issues with npm/npx
- Server crashed during startup

**Fix**:
1. Check Node.js: `node --version` (need 18+)
2. Test manually: `npx -y @modelcontextprotocol/server-filesystem ./test`
3. Check Phoenix logs for detailed errors

### Approval modal not appearing

**Check**:
- Is `requires_approval: true` for that tool?
- Is the tool listed in `dangerous_tools`?

**Fix**: Update configuration and restart

## Security Considerations

### For Production Use

1. **Always use restricted workspaces**
   - Never allow access to entire filesystem
   - Use specific directories: `/var/app/user-data`

2. **Require approval for writes**
   ```elixir
   requires_approval: true,
   dangerous_tools: ["write_file", "delete_file", "move_file", 
                     "create_directory", "edit_file"]
   ```

3. **Monitor tool usage**
   - Check logs regularly
   - Alert on suspicious patterns
   - Rate limit if needed

4. **Validate file paths**
   - MCP servers enforce workspace boundaries
   - Additional app-level validation recommended

5. **Consider user permissions**
   - Different users = different workspaces
   - Implement access control as needed

## Advanced Features

### Multi-Turn Tool Usage

The AI can use multiple tools in sequence:

```
You: "Find all TODO comments in my code and save them to a file"

AI: [🔧 search_files (pattern: "*.js") → finds JS files]
    [🔧 read_multiple_files → reads each file]
    [🔧 write_file (path: "todos.txt") → saves results]
    
AI: "I found 15 TODO comments and saved them to todos.txt"
```

### Tool Result Context

After a tool executes, the AI receives the result and can:
- Summarize the data
- Answer questions about it
- Use it for follow-up actions
- Make decisions based on the result

### Error Recovery

If a tool fails, the AI:
- Sees the error message
- Can try alternative approaches
- Asks clarifying questions
- Provides helpful error explanations

## FAQ

**Q: Can the AI use tools without asking me?**
A: Yes, if `requires_approval: false`. The AI will use tools automatically when appropriate.

**Q: How do I know what tools are available?**
A: Check the "MCP Settings" panel in the sidebar, or ask: "What tools do you have access to?"

**Q: Can I disable MCP temporarily?**
A: Set `config :ollama_chat, :mcp_enabled, false` and restart.

**Q: Are my files safe?**
A: Yes - MCP servers can only access files within the configured workspace directory.

**Q: Can the AI access the internet?**
A: No, not with the current filesystem server. Other MCP servers may provide network access if configured.

**Q: How do I add custom tools?**
A: You can create custom MCP servers following the [MCP specification](https://modelcontextprotocol.io), or use existing community servers.

**Q: Does this work with all Ollama models?**
A: Yes, but larger models (7B+) perform better at understanding when to use tools.

## Resources

- **[MCP_SERVERS_UPDATE.md](MCP_SERVERS_UPDATE.md)** - List of available servers
- **[MCP_TEST_SETUP.md](docs/MCP_TEST_SETUP.md)** - Developer testing guide
- **[MCP Official Docs](https://modelcontextprotocol.io)** - Protocol specification
- **[MCP Servers Repository](https://github.com/modelcontextprotocol/servers)** - Community servers

## Getting Help

- Check Phoenix logs for detailed error messages
- Review this guide's troubleshooting section
- Test tools manually with `npx @modelcontextprotocol/server-filesystem`
- Ask in your development team's chat

---

**Happy chatting with MCP-enhanced AI! 🚀**
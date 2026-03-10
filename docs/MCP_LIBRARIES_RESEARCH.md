# MCP (Model Context Protocol) Libraries Research

**Date**: February 27, 2026  
**Project**: Ollama Chat  
**Purpose**: Evaluate Elixir MCP client libraries for integration

## Executive Summary

**Recommendation**: Use **ex_mcp** as the primary MCP client library for Ollama Chat.

**Rationale**:
- Most comprehensive implementation (client + server)
- Multiple transport options (stdio, HTTP/SSE, native BEAM)
- Phoenix/Plug integration ready
- Active development (latest commit: March 10, 2026)
- 2600+ tests with TypeScript SDK interop
- Full MCP compliance (multiple protocol versions)
- MIT licensed
- OTP-native with supervision tree support

## Available Libraries Overview

The Hex package registry contains 36+ MCP-related packages. Key client-capable libraries:

| Library | Version | Downloads (All) | Status | Primary Use Case |
|---------|---------|-----------------|--------|------------------|
| **ex_mcp** | 0.8.3 | 501 | Active | Full client/server with Phoenix integration |
| **langchain_mcp** | 0.2.0 | 526 | Active | LangChain integration (uses anubis_mcp) |
| **hermolaos** | 0.3.0 | 54 | New | Pure MCP client |
| **aide** | 0.7.1 | 56,624 | Active | Server-focused (clients coming soon) |
| **anubis_mcp** | 0.17.1 | 64,319 | Active | Phoenix-focused MCP implementation |

## Detailed Analysis

### 1. ex_mcp (RECOMMENDED)

**GitHub**: https://github.com/azmaveth/ex_mcp  
**Hex**: https://hex.pm/packages/ex_mcp  
**Version**: 0.8.3 (March 10, 2026)  
**License**: MIT

#### Features
- ✅ **Full MCP compliance** - Supports protocol versions 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25
- ✅ **Multiple transports**:
  - HTTP/SSE (web applications, remote APIs, ~5-20ms latency)
  - stdio (subprocess communication, ~1-5ms latency)
  - Native BEAM (~15µs latency for Elixir cluster communication)
- ✅ **Phoenix integration** via `ExMCP.HttpPlug`
- ✅ **Dual API styles**:
  - DSL-based (declarative tool/resource definitions)
  - Handler-based (callback functions)
- ✅ **OAuth 2.1** support (Resource Server, JWT client auth)
- ✅ **OTP-native** with supervision trees and auto-reconnection
- ✅ **Telemetry** integration for monitoring
- ✅ **Agent Client Protocol (ACP)** support for controlling coding agents
- ✅ **2600+ tests** including TypeScript SDK interop

#### Dependencies
```elixir
{:castore, "~> 1.0"}
{:ex_json_schema, "~> 0.10"}
{:fuse, "~> 2.4", optional: true}
{:gen_state_machine, "~> 3.0"}
{:horde, "~> 0.8", optional: true}
{:jason, "~> 1.4"}
{:jose, "~> 1.11"}
{:mint, "~> 1.6"}
{:mint_web_socket, "~> 1.0"}
{:plug, "~> 1.16"}
{:plug_cowboy, "~> 2.7"}
{:telemetry, "~> 1.2"}
```

#### Example: Phoenix Integration
```elixir
# Router
scope "/api/mcp" do
  forward "/", ExMCP.HttpPlug,
    handler: MyApp.MCPHandler,
    server_info: %{name: "ollama-chat", version: "1.0.0"},
    sse_enabled: true,
    cors_enabled: true
end

# Handler
defmodule MyApp.MCPHandler do
  use ExMCP.Server.Handler

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [%{name: "search", description: "Search tool"}]
    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("search", args, state) do
    result = perform_search(args)
    {:ok, [%{type: "text", text: result}], state}
  end
end
```

#### Example: Client Usage
```elixir
# Connect to stdio-based MCP server
{:ok, client} = ExMCP.Client.start_link(
  transport: :stdio,
  command: ["node", "mcp-server-filesystem.js"]
)

# List available tools
{:ok, tools} = ExMCP.Client.list_tools(client)

# Call a tool
{:ok, result} = ExMCP.Client.call_tool(client, "read_file", %{
  path: "/path/to/file.txt"
})
```

#### Pros
- Most feature-complete solution
- Excellent documentation and examples
- Active development and maintenance
- Performance optimized (native BEAM transport option)
- Built with OTP best practices
- Comprehensive test coverage
- Phoenix-ready out of the box

#### Cons
- Larger dependency footprint (12 dependencies)
- May be over-featured if only client functionality needed
- Relatively new (but rapidly maturing)

#### Fit for Ollama Chat
**Excellent fit** - Provides everything needed:
- Client functionality for connecting to MCP servers
- Supervision tree integration
- stdio transport for local MCP servers
- HTTP/SSE for remote servers
- Native BEAM for potential distributed features
- Already designed for Phoenix apps

---

### 2. langchain_mcp

**GitHub**: https://github.com/montebrown/langchain_mcp  
**Hex**: https://hex.pm/packages/langchain_mcp  
**Version**: 0.2.0 (December 4, 2025)  
**License**: Apache-2.0

#### Features
- ✅ LangChain integration (adapters for LLM chains)
- ✅ Tool discovery and conversion
- ✅ Fallback client support
- ✅ Multi-modal content support
- ✅ Status monitoring with LiveView support
- ✅ Dynamic client management (per-job/per-request)

#### Dependencies
```elixir
{:anubis_mcp, "~> 0.16.0"}
{:langchain, "~> 0.4.0"}
{:bandit, "~> 1.0", optional: true}
{:plug, "~> 1.15", optional: true}
```

#### Pros
- Higher-level abstraction focused on LLM workflows
- Excellent fallback and retry mechanisms
- Built-in status monitoring dashboard
- Good documentation with LiveView examples

#### Cons
- Requires LangChain (additional dependency if not already used)
- Less flexible for non-LangChain use cases
- Built on anubis_mcp (indirect dependency)
- Focused on tool-calling patterns

#### Fit for Ollama Chat
**Moderate fit** - Could work but:
- Adds LangChain dependency (we're using raw Ollama API)
- Designed for function-calling workflows
- May be overkill if we don't need LangChain abstractions
- Better suited for projects already using LangChain

---

### 3. hermolaos

**GitHub**: https://github.com/nmaroulis/hermolaos  
**Hex**: https://hex.pm/packages/hermolaos  
**Version**: 0.3.0 (December 3, 2025)  
**License**: Apache-2.0

#### Features
- ✅ Pure MCP client implementation
- ✅ Simple, focused API
- ✅ Minimal dependencies

#### Dependencies
```elixir
{:jason, "~> 1.4"}
{:nimble_options, "~> 1.1"}
{:req, "~> 0.5"}
```

#### Pros
- Lightweight (only 3 dependencies)
- Uses Req (same HTTP client as Ollama Chat)
- Simple, straightforward API
- Fast to integrate

#### Cons
- Very new (first release December 2025)
- Limited documentation
- Only 54 total downloads (unproven)
- Unknown protocol version support
- No stdio transport (HTTP only based on Req dependency)
- Minimal community adoption

#### Fit for Ollama Chat
**Risky** - While attractive for simplicity:
- Too new and unproven
- Limited transport options
- Unclear protocol compliance
- Minimal community validation

---

### 4. anubis_mcp

**Hex**: https://hex.pm/packages/anubis_mcp  
**Version**: 0.17.1  
**Downloads**: 64,319 (most popular)

#### Features
- Phoenix-focused MCP implementation
- Server and client capabilities
- Used as dependency by langchain_mcp

#### Pros
- Most downloaded MCP library
- Mature and stable
- Phoenix integration

#### Cons
- Less comprehensive documentation than ex_mcp
- Primarily focused on server-side

#### Fit for Ollama Chat
**Good alternative** - Could work but ex_mcp appears more comprehensive

---

## Comparison Matrix

| Feature | ex_mcp | langchain_mcp | hermolaos | anubis_mcp |
|---------|---------|---------------|-----------|------------|
| **Client Support** | ✅ Full | ✅ Full | ✅ Limited | ✅ Full |
| **Server Support** | ✅ Yes | ❌ No | ❌ No | ✅ Yes |
| **stdio Transport** | ✅ Yes | ✅ Via anubis | ❌ No | ✅ Yes |
| **HTTP/SSE Transport** | ✅ Yes | ✅ Via anubis | ✅ Yes | ✅ Yes |
| **Native BEAM** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Phoenix Integration** | ✅ Native | ✅ Via deps | ❌ No | ✅ Yes |
| **Supervision Tree** | ✅ Yes | ✅ Yes | ❓ Unknown | ✅ Yes |
| **Protocol Versions** | ✅ 4 versions | ✅ Yes | ❓ Unknown | ✅ Yes |
| **Test Coverage** | ✅ 2600+ | ✅ Good | ❓ Unknown | ✅ Good |
| **Documentation** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ |
| **Maturity** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐ | ⭐⭐⭐⭐⭐ |
| **Active Development** | ✅ Very | ✅ Yes | ❓ Unknown | ✅ Yes |
| **Dependencies** | 12 | 4 | 3 | Medium |
| **License** | MIT | Apache-2.0 | Apache-2.0 | Unknown |

## Implementation Plan for Ollama Chat

### Phase 1: Setup & Configuration (Week 1)

1. **Add ex_mcp dependency**
   ```elixir
   # mix.exs
   {:ex_mcp, "~> 0.8.0"}
   ```

2. **Create MCP configuration**
   ```elixir
   # config/config.exs
   config :ollama_chat, :mcp_servers, [
     %{
       name: "filesystem",
       command: "npx",
       args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/workspace"],
       enabled: true
     }
   ]
   ```

3. **Create MCP client module**
   ```elixir
   # lib/ollama_chat/mcp_client.ex
   defmodule OllamaChat.MCPClient do
     @moduledoc "Manages MCP server connections"
     
     use GenServer
     require Logger
     
     def start_link(opts) do
       GenServer.start_link(__MODULE__, opts, name: __MODULE__)
     end
     
     # Client API
     def list_tools do
       GenServer.call(__MODULE__, :list_tools)
     end
     
     def call_tool(name, args) do
       GenServer.call(__MODULE__, {:call_tool, name, args})
     end
   end
   ```

### Phase 2: MCP Server Management (Week 2)

1. **Add to supervision tree**
   ```elixir
   # lib/ollama_chat/application.ex
   children = [
     # ... existing children
     {OllamaChat.MCPClient, []}
   ]
   ```

2. **Implement server lifecycle**
   - Start configured MCP servers on app startup
   - Health monitoring
   - Automatic restart on failure
   - Graceful shutdown

### Phase 3: Tool Integration (Week 3)

1. **Tool discovery and registry**
   - Query all connected MCP servers for tools
   - Build unified tool registry
   - Cache tool schemas

2. **Extend ChatLive for tool calls**
   - Parse tool call requests from LLM
   - Execute via MCP client
   - Inject results back into conversation

3. **UI indicators**
   - Show when tools are being called
   - Display tool execution status
   - Render tool results

### Phase 4: Security & UX (Week 4)

1. **User approval workflow**
   - Prompt for dangerous operations
   - Configurable tool permissions
   - Audit logging

2. **Settings UI**
   - Enable/disable MCP servers
   - View available tools
   - Configure tool permissions

## Potential Challenges

### 1. Ollama Function Calling Support
**Challenge**: Ollama may have limited or no native function calling support (unlike OpenAI/Anthropic).

**Solutions**:
- Parse tool calls from raw text using patterns/regex
- Use instruction prompting to guide tool usage format
- Consider proxy LLM for function calling (OpenAI/Anthropic for tool decisions, Ollama for general chat)
- Monitor Ollama roadmap for function calling features

### 2. Performance Considerations
**Challenge**: Multiple tool calls could slow response times.

**Solutions**:
- Use async tool execution where possible
- Show progressive UI updates
- Implement timeouts and cancellation
- Cache tool results when appropriate

### 3. Security Concerns
**Challenge**: MCP tools can perform dangerous operations (file writes, command execution).

**Solutions**:
- Implement user approval for sensitive operations
- Sandbox MCP servers when possible
- Use least-privilege principles
- Comprehensive audit logging
- Rate limiting

## Next Steps

1. ✅ **Research complete** - Document MCP libraries (this document)
2. 📋 **Prototype** - Create minimal MCP client integration POC
3. 📋 **Test with sample server** - Integrate filesystem or time MCP server
4. 📋 **Design UI/UX** - Mockups for tool calling interface
5. 📋 **Implement Phase 1** - Basic MCP client infrastructure
6. 📋 **Test with Ollama** - Evaluate function calling capabilities
7. 📋 **Iterate** - Based on findings, adjust architecture

## References

- **MCP Specification**: https://spec.modelcontextprotocol.io/
- **MCP Servers Repository**: https://github.com/modelcontextprotocol/servers
- **Anthropic MCP Docs**: https://www.anthropic.com/news/model-context-protocol
- **ex_mcp GitHub**: https://github.com/azmaveth/ex_mcp
- **langchain_mcp GitHub**: https://github.com/montebrown/langchain_mcp
- **Ollama Function Calling**: Track at https://github.com/ollama/ollama/issues

## Conclusion

**ex_mcp** is the recommended choice for Ollama Chat's MCP integration due to:
- Comprehensive feature set
- Multiple transport options
- Phoenix-ready architecture
- Active development
- Strong testing
- OTP best practices

The main risk is Ollama's limited function calling support, which will require creative solutions like structured prompting or hybrid LLM approaches.
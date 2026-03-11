# Ollama Chat

A beautiful, real-time web-based chat interface for interacting with local Ollama-hosted Large Language Models (LLMs). Built with Phoenix LiveView for a seamless, reactive user experience.

## Features

- 🚀 Real-time streaming responses from your local LLM
- 💬 Clean, modern chat interface with smooth animations
- 🎨 Beautiful gradient UI with dark theme
- 🔄 Automatic Ollama server detection and startup
- 🔀 Multi-model support with easy model switching
- 📱 Responsive design for desktop and mobile
- ⚡ Built with Phoenix LiveView for real-time updates
- 🎯 Designed for local use - just start and chat
- 🔧 **MCP (Model Context Protocol)** - AI can use external tools
  - 📁 File system operations (read, write, search files)
  - 🔌 Extensible tool system with approval workflows
  - 🛡️ Secure sandboxed workspace for file access
  - See [MCP_USER_GUIDE.md](MCP_USER_GUIDE.md) for usage instructions

## Prerequisites

- Elixir 1.15 or later
- Erlang/OTP 25 or later
- Node.js 18+ (for asset compilation)
- [Ollama](https://ollama.ai/) installed on your system

## Installation

1. **Clone or navigate to the project:**
   ```bash
   cd ollama_chat
   ```

2. **Install dependencies:**
   ```bash
   mix setup
   ```

3. **Start the Phoenix server:**
   ```bash
   mix phx.server
   ```

4. **Visit the application:**
   Open your browser and navigate to [`localhost:4000`](http://localhost:4000)

## Configuration

### Environment Variables

The application can be configured using the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `OLLAMA_BASE_URL` | Base URL for the Ollama API | `http://localhost:11434` |
| `OLLAMA_DEFAULT_MODEL` | Default LLM model to use | `llama3` |
| `OLLAMA_START_COMMAND` | Command to start Ollama if not running | None |
| `OLLAMA_CHAT_PORT` | Port to run the Phoenix server on | `4000` |
| `MCP_WORKSPACE` | Workspace directory for MCP test server filesystem operations | `~/mcp_workspace` |

### Port Configuration

The Ollama Chat application uses the following ports:

- **Phoenix Server (HTTP):** Port `4000` (default, configurable via `OLLAMA_CHAT_PORT`)
- **Ollama API:** Port `11434` (default, configurable via `OLLAMA_BASE_URL`)
- **MCP Test Server:** **No port** - uses stdio (standard input/output) communication

> **Note:** The MCP test server does not use HTTP or network ports. It communicates via stdio, so it cannot conflict with the Phoenix server or any other network services.

To change the Phoenix server port:

```bash
OLLAMA_CHAT_PORT=4001 mix phx.server
```

### Example Configuration

Create a `.env` file in the project root (optional):

```bash
# Ollama Configuration
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_DEFAULT_MODEL=llama3
OLLAMA_START_COMMAND="ollama serve"

# Phoenix Configuration
OLLAMA_CHAT_PORT=4000
```

Then load it before starting the server:

```bash
source .env
mix phx.server
```

### Automatic Ollama Startup

To enable automatic Ollama server startup when it's not running, set the `OLLAMA_START_COMMAND` environment variable:

```bash
export OLLAMA_START_COMMAND="ollama serve"
mix phx.server
```

Or on macOS with Homebrew:

```bash
export OLLAMA_START_COMMAND="brew services start ollama"
mix phx.server
```

## Usage

### Basic Chat

1. Open the application in your browser
2. Type your message in the input field at the bottom
3. Press Enter or click the "Send" button
4. Watch as the AI responds in real-time with streaming text

### Switching Models

1. Click the model dropdown in the top-right corner
2. Select your desired model from the available options
3. Continue chatting with the new model

### Clearing Chat History

Click the trash icon in the top-right corner to clear the current conversation and start fresh.

## Available Models

The application automatically detects all models installed in your local Ollama instance. To install new models, use the Ollama CLI:

```bash
# Install a model
ollama pull llama3

# List installed models
ollama list

# Remove a model
ollama rm modelname
```

Popular models you can try:
- `llama3` - Meta's Llama 3 (8B or 70B parameters)
- `mistral` - Mistral 7B
- `codellama` - Code-specialized Llama model
- `phi3` - Microsoft's Phi-3 model
- `gemma` - Google's Gemma model

## Development

### Running Tests

```bash
mix test
```

### Code Quality

Run all quality checks before committing (compilation, formatting, static analysis, type checking, and tests):

```bash
mix precommit
```

This runs:
- Compiler with warnings as errors
- Code formatter verification
- Credo static analysis
- Dialyzer type checking
- Full test suite

For detailed information about code quality tools and guidelines, see [CODE_QUALITY.md](CODE_QUALITY.md) and [QUALITY_CHECKLIST.md](QUALITY_CHECKLIST.md).

#### Individual Quality Tools

```bash
# Format code
mix format

# Static analysis
mix credo --strict

# Type checking
mix dialyzer

# Run tests
mix test
```

### Live Reload

The application includes Phoenix LiveReload for automatic browser refresh during development. Simply edit your code and save - the browser will automatically update.

### Assets

Assets are automatically compiled using esbuild and Tailwind CSS. To manually rebuild:

```bash
mix assets.build
```

## Production Deployment

### Building for Production

1. **Set required environment variables:**
   ```bash
   export SECRET_KEY_BASE=$(mix phx.gen.secret)
   export PHX_HOST=your-domain.com
   ```

2. **Build assets:**
   ```bash
   mix assets.deploy
   ```

3. **Start the server:**
   ```bash
   PHX_SERVER=true mix phx.server
   ```

### Using Releases

For production deployments, consider using Mix releases:

```bash
# Build a release
MIX_ENV=prod mix release

# Run the release
PHX_SERVER=true _build/prod/rel/ollama_chat/bin/ollama_chat start
```

## Network Access

By default, the application listens on `localhost:4000`. To allow access from other devices on your local network:

1. **Find your local IP address:**
   - macOS/Linux: `ifconfig` or `ip addr`
   - Windows: `ipconfig`

2. **Access from other devices:**
   Navigate to `http://YOUR_LOCAL_IP:4000`

Note: Make sure your firewall allows incoming connections on port 4000.

## Troubleshooting

### Ollama Not Running

If you see "Disconnected" in the status indicator:

1. Make sure Ollama is installed and running:
   ```bash
   ollama serve
   ```

2. Or set the `OLLAMA_START_COMMAND` environment variable to enable automatic startup

### Connection Refused

If you get connection errors:

1. Verify Ollama is running: `curl http://localhost:11434/api/tags`
2. Check that `OLLAMA_BASE_URL` is set correctly
3. Ensure no firewall is blocking port 11434

### No Models Available

If no models appear in the dropdown:

1. Install at least one model: `ollama pull llama3`
2. Verify models are installed: `ollama list`
3. Restart the application

### Slow Responses

If responses are slow:

1. Try a smaller model (e.g., `phi3` instead of `llama3:70b`)
2. Check your system resources (CPU/RAM usage)
3. Consider using GPU acceleration if available

## Architecture

- **Backend:** Elixir + Phoenix Framework
- **Frontend:** Phoenix LiveView with Tailwind CSS
- **HTTP Client:** Req (native Elixir HTTP client)
- **Real-time:** Phoenix LiveView for WebSocket-based streaming
- **LLM API:** Ollama REST API

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is open source and available under the MIT License.

## Acknowledgments

- Built with [Phoenix Framework](https://phoenixframework.org/)
- Powered by [Ollama](https://ollama.ai/)
- UI components inspired by modern chat interfaces

## Support

For issues, questions, or contributions, please open an issue on the project repository.
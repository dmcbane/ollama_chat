# Quick Start Guide - Ollama Chat

Get up and running with Ollama Chat in 5 minutes!

## Prerequisites

Before you begin, make sure you have:

- ✅ Elixir 1.15+ installed (`elixir --version`)
- ✅ Erlang/OTP 25+ installed (`erl -version`)
- ✅ Node.js 18+ installed (`node --version`)
- ✅ [Ollama](https://ollama.ai/) installed (`ollama --version`)

## Step 1: Install Dependencies

```bash
cd ollama_chat
mix setup
```

This command will:
- Install Elixir dependencies
- Install Node.js dependencies
- Set up esbuild and Tailwind CSS
- Build assets

## Step 2: Install an Ollama Model

If you haven't already, pull at least one model:

```bash
# Install the default model (Llama 3)
ollama pull llama3

# Or try a smaller, faster model
ollama pull phi3
```

## Step 3: Start Ollama Server

Make sure Ollama is running:

```bash
ollama serve
```

Leave this terminal open, or run it in the background.

## Step 4: Start Phoenix Server

In a new terminal, start the Phoenix server:

```bash
cd ollama_chat
mix phx.server
```

You should see output like:
```
[info] Running OllamaChatWeb.Endpoint with Bandit 1.5.x at 127.0.0.1:4000 (http)
[watch] build finished, watching for changes...
```

## Step 5: Open Your Browser

Visit [http://localhost:4000](http://localhost:4000)

You should see the Ollama Chat interface with:
- A green "Connected" status indicator (if Ollama is running)
- An empty chat area
- A message input box at the bottom

## Start Chatting! 🎉

1. Type a message in the input box
2. Press Enter or click "Send"
3. Watch the AI respond in real-time

Example first messages:
- "Hello! Who are you?"
- "Write a haiku about programming"
- "Explain quantum computing in simple terms"

## Optional: Enable Auto-Start

To automatically start Ollama when the app launches, set an environment variable:

```bash
export OLLAMA_START_COMMAND="ollama serve"
mix phx.server
```

Or add it to your `.env` file:

```bash
cp .env.example .env
# Edit .env and uncomment the OLLAMA_START_COMMAND line
```

## Troubleshooting

### "Disconnected" Status

**Problem:** Red or yellow status indicator

**Solution:**
1. Make sure Ollama is running: `ollama serve`
2. Test Ollama API: `curl http://localhost:11434/api/tags`
3. Restart Phoenix server: `Ctrl+C` twice, then `mix phx.server`

### No Models in Dropdown

**Problem:** Model selector is empty or missing

**Solution:**
1. Install a model: `ollama pull llama3`
2. Verify: `ollama list`
3. Refresh the browser

### "Failed to compile" Errors

**Problem:** Mix compilation errors

**Solution:**
```bash
# Clean and rebuild
mix deps.clean --all
mix deps.get
mix compile
```

### Port Already in Use

**Problem:** `EADDRINUSE` error on port 4000

**Solution:**
```bash
# Use a different port
PORT=4001 mix phx.server
```

Then visit http://localhost:4001

## Next Steps

- 📖 Read the full [README.md](README.md) for detailed configuration
- 🎨 Explore different models with the model selector
- 🔧 Configure environment variables in `.env`
- 🌐 Access from other devices on your network (see README)

## Quick Commands Reference

```bash
# Start development server
mix phx.server

# Run tests
mix test

# Code quality checks
mix precommit

# Format code
mix format

# Install new model
ollama pull <model-name>

# List installed models
ollama list
```

## Need Help?

- Check [README.md](README.md) for full documentation
- Review [AGENTS.md](AGENTS.md) for project guidelines
- Test Ollama: `curl http://localhost:11434/api/tags`
- Check logs in the Phoenix terminal for errors

---

**Happy chatting!** 🚀
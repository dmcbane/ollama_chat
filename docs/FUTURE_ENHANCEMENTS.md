# Future Enhancements

This document captures potential improvements and design changes for future development.

## Auto-Start and Recovery Improvements

### Current Design

The current auto-start implementation has Ollama recovery logic split between two layers:

1. **OllamaClient Layer**: Catches connection errors and attempts to start Ollama internally
   - Calls `ensure_ollama_running()` when connection is refused
   - Polls for Ollama to be ready (up to 10 seconds)
   - Recursively retries the request after successful start
   - Returns results/errors to the LiveView

2. **LiveView Layer**: Handles errors returned from OllamaClient
   - Detects connection errors
   - Shows status messages to the user
   - Attempts recovery via `handle_info(:attempt_recovery, ...)`
   - Updates UI based on recovery results

### Limitations

1. **Duplicate Recovery Logic**: Both layers attempt recovery, leading to confusion about which is responsible
2. **UI Not Updated During Internal Recovery**: When OllamaClient starts Ollama internally, the LiveView doesn't know, so:
   - Status indicator stays "Disconnected"
   - Model list doesn't refresh with newly available models
   - User sees no feedback during the ~7-10 second startup process
3. **Model Name Mismatch**: If page loads before Ollama is ready, `selected_model` uses the config default (e.g., `qwen3`) instead of the actual model name with tag (e.g., `qwen3:8b`)
4. **No Progress Indication**: User doesn't know that Ollama is being started until it either succeeds or fails

### Proposed Robust Design

Move all recovery logic to the LiveView layer for better UI control:

#### Architecture Changes

```
┌─────────────────────────────────────────┐
│         LiveView (ChatLive)             │
│  - Detects connection errors            │
│  - Orchestrates recovery                │
│  - Updates UI during all phases         │
│  - Reloads models after recovery        │
└─────────────────────────────────────────┘
                    │
                    │ Pure API calls (no recovery)
                    ▼
┌─────────────────────────────────────────┐
│      OllamaClient (Pure API Layer)      │
│  - Makes HTTP requests                  │
│  - Returns errors without retry         │
│  - Provides start_ollama/0 helper       │
│  - Provides ollama_running?/0 checker   │
└─────────────────────────────────────────┘
```

#### Implementation Steps

1. **Remove auto-recovery from OllamaClient.chat_stream/3**
   - Remove the `if connection_refused?()` block
   - Let errors bubble up to LiveView immediately
   - Keep `start_ollama/0` and `ensure_ollama_running/0` as public helpers

2. **Enhance LiveView recovery handler**
   ```elixir
   def handle_info({:attempt_recovery, message_id}, socket) do
     socket = assign(socket, :status_message, "Ollama not running. Starting server...")
     
     case OllamaClient.ensure_ollama_running() do
       :ok ->
         # Reload models to get correct names with tags
         send(self(), :load_models)
         
         # Update status
         send(self(), :check_ollama_status)
         
         # Retry the original message
         send(self(), {:retry_message, message_id})
         
         assign(socket, :status_message, "Ollama started successfully!")
         
       {:error, reason} ->
         assign(socket, :error, "Failed to start Ollama: #{reason}")
     end
   end
   ```

3. **Add progress indicators**
   - Show step-by-step status: "Starting Ollama..." → "Waiting for initialization..." → "Loading models..." → "Ready!"
   - Use a progress bar or spinner
   - Estimated time remaining

4. **Auto-update model selection**
   - After loading models, if `selected_model` doesn't have a tag, match it to the full model name
   - Example: `qwen3` → `qwen3:8b`
   - Fall back to first available model if no match

5. **Add Option A and C from earlier discussion**
   - **Option A**: Auto-start on page load (configurable via environment variable)
   - **Option C**: Manual "Start Ollama" button when disconnected
   
   ```elixir
   # In mount/3
   if connected?(socket) do
     send(self(), :check_ollama_status)
     
     if Application.get_env(:ollama_chat, :auto_start_on_load, false) do
       send(self(), :ensure_ollama_started)
     end
   end
   ```

#### UI Improvements

1. **Connection Status Widget**
   ```
   ┌─────────────────────────────────────┐
   │ ● Disconnected                      │
   │ [Start Ollama] [Retry Connection]   │
   └─────────────────────────────────────┘
   ```

2. **Recovery Progress**
   ```
   ┌─────────────────────────────────────┐
   │ ⟳ Starting Ollama server...         │
   │ ░░░░░░░░░░░░░░░░░░░░ 50%            │
   └─────────────────────────────────────┘
   ```

3. **Model Selector Enhancement**
   - Disable when disconnected
   - Auto-refresh when connection restored
   - Show warning if selected model isn't available

### Benefits

1. **Single Source of Truth**: LiveView controls all recovery logic
2. **Better User Experience**: Real-time status updates during startup
3. **Accurate Model Names**: Models reloaded after startup ensures correct names
4. **User Control**: Manual start button gives users agency
5. **Clearer Code**: Separation of concerns between API layer and UI layer
6. **Testability**: Easier to test recovery flows in LiveView tests

### Configuration

Add new environment variables for user control:

```bash
# Auto-start Ollama when page loads (default: false)
OLLAMA_AUTO_START_ON_LOAD=true

# Max time to wait for Ollama startup (seconds, default: 10)
OLLAMA_STARTUP_TIMEOUT=15

# Show detailed startup progress (default: true)
OLLAMA_SHOW_STARTUP_PROGRESS=true
```

### Migration Path

1. Implement new LiveView recovery handler alongside existing code
2. Add feature flag to toggle between old and new behavior
3. Test thoroughly with flag enabled
4. Remove old OllamaClient recovery logic
5. Remove feature flag

### Related Enhancements

- **Health Checks**: Periodic background checks to detect when Ollama stops
- **Reconnection Strategy**: Exponential backoff for connection retries
- **Multiple Ollama Instances**: Support connecting to different Ollama servers
- **Model Preloading**: Warm up frequently-used models on startup
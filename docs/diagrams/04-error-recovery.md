# Error Recovery Flow

Connection failures trigger automatic Ollama restart attempts when `OLLAMA_START_COMMAND` is configured.

```mermaid
stateDiagram-v2
    [*] --> Streaming: User sends message

    Streaming --> StreamDone: Success
    Streaming --> StreamError: Error received

    StreamError --> CheckConnection: handle_info stream_error
    CheckConnection --> ShowError: Not a connection error
    CheckConnection --> AttemptRecovery: Connection error<br/>(econnrefused/timeout)

    AttemptRecovery --> SpawnRecovery: Show status message<br/>"Attempting to reconnect..."
    SpawnRecovery --> EnsureRunning: spawn ensure_ollama_running/0

    EnsureRunning --> AlreadyRunning: ollama_running?() == true
    EnsureRunning --> StartOllama: ollama_running?() == false

    StartOllama --> NoCommand: OLLAMA_START_COMMAND not set
    StartOllama --> RunCommand: Execute start command

    RunCommand --> WaitReady: Poll ollama_running?()<br/>up to 10 seconds
    WaitReady --> RecoverySuccess: Ollama responds
    WaitReady --> RecoveryFailed: Timeout after 10s

    AlreadyRunning --> RecoverySuccess
    NoCommand --> RecoveryFailed

    RecoverySuccess --> LoadModels: Reload available models
    LoadModels --> [*]: Status: running

    RecoveryFailed --> ShowError
    ShowError --> [*]: Display error to user

    StreamDone --> [*]: Update status: running
```

Recovery happens in two layers:
1. **OllamaClient level**: `chat/2` and `chat_stream/3` detect `:econnrefused`, call `ensure_ollama_running/0`, sleep 2s, then retry
2. **ChatLive level**: `{:stream_error, ...}` triggers `{:attempt_recovery, ...}` which spawns a recovery process and updates UI status

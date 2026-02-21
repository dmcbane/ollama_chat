# Error Recovery Flow

Connection failures trigger automatic Ollama restart attempts when `OLLAMA_START_COMMAND` is configured.

```mermaid
stateDiagram-v2
    [*] --> Streaming: User sends message

    Streaming --> StreamDone: Success
    Streaming --> StreamError: Error received

    StreamError --> CheckConnection: handle_info stream_error
    CheckConnection --> ShowError: Not connection error
    CheckConnection --> AttemptRecovery: econnrefused or timeout

    AttemptRecovery --> SpawnRecovery: Show reconnecting status
    SpawnRecovery --> EnsureRunning: spawn ensure_ollama_running

    EnsureRunning --> AlreadyRunning: already running
    EnsureRunning --> StartOllama: not running

    StartOllama --> NoCommand: no start command set
    StartOllama --> RunCommand: execute start command

    RunCommand --> WaitReady: poll up to 10 seconds
    WaitReady --> RecoverySuccess: Ollama responds
    WaitReady --> RecoveryFailed: timeout

    AlreadyRunning --> RecoverySuccess
    NoCommand --> RecoveryFailed

    RecoverySuccess --> LoadModels: reload models
    LoadModels --> [*]

    RecoveryFailed --> ShowError
    ShowError --> [*]

    StreamDone --> [*]
```

Recovery happens in two layers:
1. **OllamaClient level**: `chat/2` and `chat_stream/3` detect `:econnrefused`, call `ensure_ollama_running/0`, sleep 2s, then retry
2. **ChatLive level**: `{:stream_error, ...}` triggers `{:attempt_recovery, ...}` which spawns a recovery process and updates UI status

# HTTP/WebSocket Request Flow

All user interaction goes through a single LiveView mounted at `/`. Static assets are served by `Plug.Static`.

```mermaid
sequenceDiagram
    participant Browser
    participant Endpoint as OllamaChatWeb.Endpoint
    participant Router as OllamaChatWeb.Router
    participant ChatLive as OllamaChatWeb.ChatLive
    participant Client as OllamaChat.OllamaClient
    participant Ollama as Ollama API<br/>localhost:11434

    Browser->>Endpoint: GET / (initial HTTP)
    Endpoint->>Router: pipe_through :browser
    Router->>ChatLive: mount/3 (disconnected)
    ChatLive-->>Browser: Static HTML

    Browser->>Endpoint: WebSocket /live
    Endpoint->>ChatLive: mount/3 (connected)
    ChatLive->>ChatLive: send(:check_ollama_status)
    ChatLive->>ChatLive: send(:load_models)
    ChatLive->>Client: ollama_running?/0
    Client->>Ollama: GET /api/tags
    Ollama-->>Client: 200 OK
    Client-->>ChatLive: true
    ChatLive->>Client: list_models/0
    Client->>Ollama: GET /api/tags
    Ollama-->>Client: {models: [...]}
    Client-->>ChatLive: {:ok, ["llama3", ...]}
    ChatLive-->>Browser: assigns updated via WebSocket
```

The Endpoint plug pipeline: `Plug.Static` → `LiveReloader` (dev) → `RequestId` → `Telemetry` → `Parsers` → `MethodOverride` → `Head` → `Session` → `Router`.

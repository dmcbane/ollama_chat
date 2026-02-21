# OTP Supervision Tree

The application uses a `:one_for_one` supervision strategy — if any child crashes, only that child is restarted.

```mermaid
graph TD
    A["OllamaChat.Application<br/>(Application)"] --> B["OllamaChat.Supervisor<br/>strategy: :one_for_one"]
    B --> C["OllamaChatWeb.Telemetry<br/>(Telemetry supervisor)"]
    B --> D["DNSCluster<br/>(Distributed clustering)"]
    B --> E["Phoenix.PubSub<br/>name: OllamaChat.PubSub"]
    B --> F["OllamaChatWeb.Endpoint<br/>(HTTP/WebSocket server)"]
```

There is no database supervisor or GenServer processes — `OllamaClient` is a stateless module with plain functions, not a supervised process.

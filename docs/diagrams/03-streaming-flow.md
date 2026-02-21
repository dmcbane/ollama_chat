# Chat Streaming Flow

When the user sends a message, a spawned process streams NDJSON chunks from Ollama back to the LiveView via message passing.

```mermaid
sequenceDiagram
    participant User as Browser
    participant LV as ChatLive<br/>(LiveView process)
    participant Spawn as Spawned Process
    participant Client as OllamaClient
    participant Ollama as Ollama API

    User->>LV: phx-submit "send"
    LV->>LV: stream_insert user message
    LV->>LV: stream_insert assistant placeholder<br/>(streaming: true)
    LV->>LV: assign loading: true
    LV-->>User: UI update (messages visible)

    LV->>Spawn: spawn(fn -> chat_stream(...) end)

    Spawn->>Client: chat_stream(messages, callback, model)
    Client->>Ollama: POST /api/chat<br/>{stream: true}

    loop NDJSON chunks
        Ollama-->>Client: {"message":{"content":"chunk"}, "done":false}
        Client->>Client: Parse JSON, invoke callback
        Client->>Spawn: callback.(chunk)
        Spawn->>LV: send {:stream_chunk, id, content}
        LV->>LV: Accumulate in streaming_message
        LV->>LV: stream_insert updated assistant msg
        LV-->>User: UI update (content growing)
    end

    Ollama-->>Client: {"done":true}
    Client->>Spawn: callback.(done_chunk)
    Spawn->>LV: send {:stream_done, id}
    LV->>LV: Finalize message (streaming: false)
    LV->>LV: Update message_history
    LV->>User: push_event "save_conversation"
    User->>User: localStorage.setItem(...)
    User->>LV: pushEvent "conversation_saved"
```

Key design decisions:
- Streaming runs in a **spawned process** to avoid blocking the LiveView
- Content is **accumulated** in `streaming_message` assign and re-inserted into the stream on each chunk
- On completion, the conversation is **auto-saved to browser localStorage** via a `push_event`

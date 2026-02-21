# ChatLive State & Event Map

## Socket Assigns

```mermaid
graph LR
    subgraph "UI State"
        loading["loading: boolean"]
        error["error: string | nil"]
        status["status_message: string | nil"]
        form["form: Phoenix.HTML.Form"]
        empty["messages_empty?: boolean"]
    end

    subgraph "Ollama State"
        ollama_status["ollama_status:<br/>:running | :stopped | :unknown"]
        models["available_models: list"]
        selected["selected_model: string"]
    end

    subgraph "Message State"
        stream["@streams.messages<br/>(Phoenix Stream)"]
        history["message_history: list<br/>(stack, newest first)"]
        streaming["streaming_message: string<br/>(accumulator)"]
    end

    subgraph "Conversation Persistence"
        convos["conversations: list<br/>(from localStorage)"]
        current_id["current_conversation_id:<br/>string | nil"]
        warning["storage_warning: boolean"]
    end
```

## Event Handlers

```mermaid
graph TD
    subgraph "handle_event (user actions)"
        E1["'validate' → update form assign"]
        E2["'send' → add messages, spawn stream"]
        E3["'select_model' → update selected_model"]
        E4["'clear_chat' → reset all state"]
        E5["'load_conversation' → push_event to JS"]
        E6["'conversation_loaded' → restore from localStorage"]
        E7["'conversations_loaded' → update list"]
        E8["'conversation_saved' → store conversation_id"]
    end

    subgraph "handle_info (internal messages)"
        I1[":check_ollama_status → poll health"]
        I2[":load_models → fetch model list"]
        I3["{:stream_chunk, id, content} → accumulate"]
        I4["{:stream_done, id} → finalize + auto-save"]
        I5["{:stream_error, id, reason} → recovery or error"]
        I6["{:attempt_recovery, id} → spawn restart"]
        I7["{:recovery_success, id} → clear error"]
        I8["{:recovery_failed, reason} → show error"]
        I9[":clear_status → nil status_message"]
    end
```

## Client ↔ Server Event Bridge

Conversation persistence uses `push_event` / `pushEvent` to bridge LiveView and browser localStorage:

```mermaid
graph LR
    subgraph "Server (ChatLive)"
        PE1["push_event 'save_conversation'"]
        PE2["push_event 'load_conversation'"]
        PE3["push_event 'new_conversation'"]
    end

    subgraph "Client (.ConversationManager hook)"
        HE1["handleEvent 'save_conversation'<br/>→ localStorage.setItem"]
        HE2["handleEvent 'load_conversation'<br/>→ find + pushEvent"]
        HE3["handleEvent 'new_conversation'<br/>→ reload list"]
    end

    subgraph "Client → Server"
        CE1["pushEvent 'conversation_saved'"]
        CE2["pushEvent 'conversation_loaded'"]
        CE3["pushEvent 'conversations_loaded'"]
        CE4["pushEvent 'storage_warning'"]
    end

    PE1 --> HE1
    PE2 --> HE2
    PE3 --> HE3
    HE1 --> CE1
    HE2 --> CE2
    HE1 --> CE3
    HE3 --> CE3
```

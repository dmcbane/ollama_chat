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

## Document Attachments

### Overview

Enable users to attach documents to chat messages, providing context from existing files for the LLM to reference and discuss.

### Supported Document Types (Phase 1)

Initially support common document formats, all converted to plain text/markdown before storing:

1. **PDF Documents** (`.pdf`)
   - Extract text content using a library like `pdf_text` or `poppler`
   - Preserve basic formatting (headings, paragraphs, lists)
   - Convert to markdown structure

2. **Word Documents** (`.docx`, `.doc`)
   - Parse using `docx` parsing libraries
   - Extract text, headings, and basic formatting
   - Convert to markdown

3. **Plain Text Documents** (`.txt`, `.md`)
   - Direct inclusion with minimal processing
   - Markdown files used as-is
   - Text files wrapped in appropriate markdown structure

4. **Rich Text Format** (`.rtf`)
   - Parse and extract text content
   - Convert formatting to markdown equivalents

### Architecture

```
┌─────────────────────────────────────────┐
│     User uploads document via UI        │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│   Phoenix.LiveView.allow_upload/3       │
│   - Validate file type and size         │
│   - Temporary storage in /tmp           │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│   DocumentProcessor Module              │
│   - Detect document type                │
│   - Route to appropriate converter      │
│   - Return markdown text                │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│   Store as part of chat message         │
│   - Prepend to user message content     │
│   - Format: [Attached: filename.pdf]    │
│   - Include full markdown text          │
└─────────────────────────────────────────┘
```

### Implementation Details

#### 1. LiveView Upload Configuration

```elixir
# In ChatLive.mount/3
socket =
  socket
  |> allow_upload(:document,
    accept: ~w(.pdf .docx .doc .txt .md .rtf),
    max_entries: 1,
    max_file_size: 10_000_000,  # 10MB
    auto_upload: true
  )
```

#### 2. Document Processor Module

```elixir
defmodule OllamaChat.DocumentProcessor do
  @moduledoc """
  Converts various document formats to markdown text.
  """
  
  def process_upload(path, filename) do
    case Path.extname(filename) do
      ".pdf" -> process_pdf(path)
      ".docx" -> process_docx(path)
      ".txt" -> process_text(path)
      ".md" -> process_markdown(path)
      ext -> {:error, "Unsupported file type: #{ext}"}
    end
  end
  
  defp process_pdf(path) do
    # Use pdf_text or similar library
    # Return {:ok, markdown_text}
  end
  
  defp process_docx(path) do
    # Use docx parser
    # Return {:ok, markdown_text}
  end
  
  defp process_text(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      error -> error
    end
  end
end
```

#### 3. Message Format with Attachments

When a document is attached, prepend its content to the user's message:

```markdown
[Attached Document: requirements.pdf]

# Requirements Document
(converted markdown content here...)

---

User's actual message: "Can you summarize the key requirements from this document?"
```

#### 4. UI Components

Add upload button to the message input area:

```heex
<div class="flex gap-2">
  <.live_file_input upload={@uploads.document} class="hidden" />
  <button
    type="button"
    phx-click={JS.dispatch("click", to: "#document-upload")}
    class="p-2 text-gray-400 hover:text-white"
    title="Attach document"
  >
    <.icon name="hero-paper-clip" class="w-5 h-5" />
  </button>
  
  <%= if @uploads.document.entries != [] do %>
    <span class="text-sm text-gray-400">
      Attached: <%= List.first(@uploads.document.entries).client_name %>
    </span>
  <% end %>
</div>
```

### Dependencies

Add required packages to `mix.exs`:

```elixir
{:pdf_text, "~> 0.1"},  # For PDF extraction
{:sweet_xml, "~> 0.7"},  # For DOCX parsing (XML-based)
```

### File Size Limits

- **Maximum file size**: 10MB (configurable)
- **Maximum text output**: 50,000 characters (truncate with notice if exceeded)
- **Supported files per message**: 1 initially (expand to multiple in Phase 2)

### Storage Considerations

Since attachments are converted to text and stored in localStorage:

1. **Monitor localStorage usage** - Large documents can fill quota quickly
2. **Provide compression** - Consider gzip compression for stored conversations
3. **Warn users** - Show estimated storage impact before attachment
4. **Implement cleanup** - Auto-delete old conversations when quota is low

### User Experience

1. **Drag-and-drop support** - Drag files directly into chat area
2. **Preview before sending** - Show first few lines of extracted text
3. **Progress indicator** - Display processing status for large files
4. **Error handling** - Clear messages for unsupported formats or corrupted files
5. **Visual indicator** - Show attachment icon in message bubble

### Future Phases

#### Phase 2: Enhanced Document Support
- **Multiple attachments** per message
- **Image extraction** from PDFs (for vision models)
- **Spreadsheets** (`.xlsx`, `.csv`) converted to markdown tables
- **Code files** with syntax preservation
- **Archive support** (`.zip`) with multiple files

#### Phase 3: Advanced Features
- **Document indexing** - Reference previous attachments across conversations
- **OCR support** - Extract text from scanned PDFs/images
- **Web scraping** - Attach content from URLs
- **Integration with cloud storage** (Google Drive, Dropbox)
- **Version tracking** - Track changes to attached documents

#### Phase 4: Vision Model Integration
- **Direct image support** - For multimodal models (LLaVA, GPT-4V)
- **Diagram understanding** - Charts, graphs, flowcharts
- **Screenshot analysis** - Discuss UI/UX designs
- **Handwriting recognition** - Notes and sketches

### Security Considerations

1. **File validation** - Verify file types, not just extensions
2. **Malware scanning** - Consider ClamAV integration for production
3. **Size limits** - Prevent DoS via large file uploads
4. **Temporary file cleanup** - Delete uploaded files after processing
5. **Content sanitization** - Strip macros, scripts from documents

### Performance Optimization

1. **Async processing** - Handle conversion in background process
2. **Caching** - Cache converted documents by hash
3. **Streaming** - Process large documents in chunks
4. **Timeout handling** - Limit processing time per document

### Configuration

Add environment variables:

```bash
# Document attachment settings
OLLAMA_CHAT_MAX_ATTACHMENT_SIZE=10485760  # 10MB in bytes
OLLAMA_CHAT_MAX_ATTACHMENT_TEXT_LENGTH=50000  # Max chars from conversion
OLLAMA_CHAT_ENABLE_ATTACHMENTS=true  # Feature flag
```

### Testing Strategy

1. **Unit tests** - Document conversion for each format
2. **Integration tests** - Upload flow end-to-end
3. **Performance tests** - Large file handling
4. **Edge cases** - Corrupted files, empty files, encoding issues
5. **Browser tests** - Upload UI with various file sizes

### Benefits

1. **Enhanced Context** - LLM can reference specific documents
2. **Productivity** - Discuss reports, analyze documents without manual copying
3. **Accessibility** - Easier than copy-pasting large documents
4. **Version Control** - Attachments stored with conversation history
5. **Multimodal Ready** - Foundation for future image/vision support
# Future Enhancements

This document captures potential improvements and design changes for future development.

## Auto-Start and Recovery (Implemented)

Recovery logic has been consolidated into the LiveView layer. OllamaClient is now a pure API layer that returns errors immediately without internal retry. ChatLive orchestrates all recovery with step-by-step UI feedback:

- **"Start Ollama" button** shown when Ollama is stopped and `OLLAMA_START_COMMAND` is configured
- **3-step progress bar** during recovery: Starting → Waiting → Loading Models
- **Guard against duplicate recovery** via `:recovering` assign

### Remaining Future Work

- **Auto-start on page load** — configurable via `OLLAMA_AUTO_START_ON_LOAD` environment variable
- **Health checks** — periodic background polling to detect when Ollama stops unexpectedly
- **Exponential backoff** — smarter retry strategy for intermittent connection failures
- **Model preloading** — warm up frequently-used models after startup

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
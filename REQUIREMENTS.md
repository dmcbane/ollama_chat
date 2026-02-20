# Ollama Chat Requirements

This document describes the functional requirements and expected behavior for the Ollama Chat application.

## Table of Contents

- [System Architecture](#system-architecture)
- [Ollama Integration](#ollama-integration)
- [Chat Interface](#chat-interface)
- [Message Streaming](#message-streaming)
- [Model Management](#model-management)
- [Conversation Management](#conversation-management)
- [Error Handling and Recovery](#error-handling-and-recovery)
- [User Interface and Experience](#user-interface-and-experience)
- [Configuration](#configuration)
- [Security](#security)
- [Testing](#testing)
- [Future Enhancements](#future-enhancements)

---

## System Architecture

### Technology Stack

**Requirement**: Ollama Chat MUST be built with the following technology stack:

- **Elixir 1.15+** on Erlang/OTP 25+ (BEAM virtual machine)
- **Phoenix 1.8** web framework
- **Phoenix LiveView 1.1** for real-time reactive UI
- **Bandit** HTTP/2 server adapter
- **Tailwind CSS** for styling
- **Req** HTTP client for API communication

**Rationale**: Phoenix LiveView provides real-time streaming UI updates over WebSockets without requiring a separate JavaScript frontend framework. The BEAM VM provides fault tolerance and lightweight concurrency well-suited for streaming responses.

### Application Architecture

**Requirement**: The application MUST follow Phoenix conventions with clear separation of concerns.

**Architecture Overview**:
```
Browser (WebSocket)
  └── Phoenix LiveView (ChatLive)
      ├── UI State Management (socket assigns)
      ├── Message Stream (Phoenix streams)
      └── OllamaClient (HTTP API client)
          └── Ollama API (localhost:11434)
```

**Module Responsibilities**:

| Module | Responsibility |
|--------|---------------|
| `OllamaChat.Application` | OTP supervision tree, service startup |
| `OllamaChat.OllamaClient` | Ollama API client, HTTP requests, retry/recovery logic |
| `OllamaChatWeb.ChatLive` | Main UI component, message handling, streaming state |
| `OllamaChatWeb.Router` | HTTP routing, single route to ChatLive |
| `OllamaChatWeb.Endpoint` | Phoenix endpoint, WebSocket/HTTP configuration |
| `OllamaChatWeb.Telemetry` | Metrics and monitoring |
| `OllamaChatWeb.CoreComponents` | Reusable UI components (buttons, forms, icons) |
| `OllamaChatWeb.Layouts` | Root HTML layout and flash message display |

**Implementation Notes**:
- Application supervisor: `lib/ollama_chat/application.ex`
- Supervision tree: Telemetry → DNSCluster → PubSub → Endpoint
- Strategy: `:one_for_one` (independent child restarts)

### OTP Supervision Tree

**Requirement**: The application MUST use an OTP supervision tree for fault-tolerant process management.

```
OllamaChat.Supervisor (:one_for_one)
├── OllamaChatWeb.Telemetry      (metrics collection)
├── DNSCluster                    (distributed mode support)
├── Phoenix.PubSub                (message broadcasting)
└── OllamaChatWeb.Endpoint        (HTTP/WebSocket server)
```

### Stateless Design

**Requirement**: The application MUST operate without a traditional database.

- All conversation state exists only in the LiveView process memory (`socket.assigns`)
- Chat history is lost on page refresh or session disconnection
- No persistent storage of messages, user data, or preferences
- Configuration is provided entirely through environment variables

**Current Limitations**:
- No conversation persistence across sessions
- No multi-user data isolation
- No conversation export/import
- Single-session only (refreshing the page clears all history)

**Rationale**: The MVP focuses on providing a lightweight, zero-dependency chat interface. Persistent storage is planned as a future enhancement (see [Future Enhancements](#future-enhancements)).

---

## Ollama Integration

### API Client

**Requirement**: The application MUST communicate with a local Ollama instance via its HTTP API.

**Supported Endpoints**:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/tags` | GET | List available models, health check |
| `/api/chat` | POST | Send chat messages (streaming and non-streaming) |

**Implementation Notes**:
- Client module: `lib/ollama_chat/ollama_client.ex`
- Uses `Req` HTTP client (not HTTPoison or Tesla)
- Base URL configurable via `OLLAMA_BASE_URL` (default: `http://localhost:11434`)
- All API calls use `retry: false` to handle retries manually with recovery logic

### Health Checking

**Requirement**: The application MUST verify Ollama connectivity on page load.

- On LiveView mount, the application MUST send `:check_ollama_status` message
- Health check MUST use the `/api/tags` endpoint with a 2-second timeout
- Status MUST be one of: `:running`, `:stopped`, or `:unknown`
- Status MUST be reflected visually in the UI header (green/red/yellow indicator)

**Behavior**:
1. On initial page load, status starts as `:unknown` (yellow indicator)
2. Background check fires after WebSocket connection established
3. Status updates to `:running` (green) or `:stopped` (red)
4. No periodic polling — status only checked on mount and after errors

### Streaming Chat API

**Requirement**: Chat responses MUST be streamed in real-time from Ollama.

**Request Format**:
```json
{
  "model": "llama3",
  "messages": [
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": "Hi there!"},
    {"role": "user", "content": "How are you?"}
  ],
  "stream": true
}
```

**Response Format**: Newline-delimited JSON (NDJSON)
```json
{"message": {"content": "I'm"}, "done": false}
{"message": {"content": " doing"}, "done": false}
{"message": {"content": " great!"}, "done": false}
{"message": {"content": ""}, "done": true}
```

**Processing Rules**:
- Each line of the response MUST be parsed as independent JSON
- Invalid JSON lines MUST be silently skipped (not crash the stream)
- The `done: true` signal MUST trigger stream finalization
- The streaming callback MUST send messages back to the LiveView process via `send/2`

**Implementation Notes**:
- Streaming uses `Req.post/2` with the `into:` option for chunked response handling
- Each chunk is split by newlines and parsed individually
- Streaming runs in a spawned process to avoid blocking the LiveView

### Non-Streaming Chat API

**Requirement**: The application MUST also support non-streaming chat requests.

- Non-streaming mode sends `stream: false` in the request body
- Returns a single complete response body
- Used for potential future features (summarization, title generation)

---

## Chat Interface

### Message Display

**Requirement**: The chat interface MUST display messages in a scrollable container with visual role distinction.

**Message Types**:

| Role | Alignment | Style |
|------|-----------|-------|
| User | Right-aligned | Blue background (`bg-blue-600`), rounded with `rounded-tr-sm` |
| Assistant | Left-aligned | Slate background (`bg-slate-700`), rounded with `rounded-tl-sm` |

**Display Rules**:
- Messages MUST be displayed in chronological order
- Messages MUST preserve whitespace and line breaks (`whitespace-pre-wrap`)
- Messages MUST wrap long words (`break-words`)
- Messages MUST be limited to 80% max width of the container
- New messages MUST animate in with a fade-in effect (`animate-fade-in`)
- The message container MUST auto-scroll to the bottom when new messages arrive

**Empty State**:
- When no messages exist, the chat area MUST show a centered placeholder:
  - A chat bubble icon (`hero-chat-bubble-left-right`, 16x16)
  - Text: "Start a conversation with your local LLM"

### Streaming Indicator

**Requirement**: While an assistant response is streaming, the UI MUST indicate active generation.

- A pulsing cursor (white block, `w-2 h-4`, `animate-pulse`) MUST appear at the end of the streaming message
- The cursor MUST be removed when streaming completes
- The Send button MUST show a spinning icon and "Sending..." text during streaming
- The textarea MUST be disabled during streaming

### Message Container

**Requirement**: The message container MUST have a fixed height with scrolling.

- Container height: `600px` (`h-[600px]`)
- Overflow: Vertical scroll (`overflow-y-auto`)
- Background: Semi-transparent slate (`bg-slate-800/50`) with backdrop blur
- Border: Slate border with rounded corners (`rounded-xl`, `border-slate-700`)

**Implementation Notes**:
- Messages use Phoenix streams (`phx-update="stream"`) for efficient DOM updates
- Auto-scroll implemented via `.ScrollToBottom` colocated hook
- Hooks defined inline in `chat_live.ex` using `Phoenix.LiveView.ColocatedHook`

### Input Form

**Requirement**: The chat input MUST be a multi-line textarea with a Send button.

**Textarea Behavior**:
- Type: `textarea` (not single-line input)
- Default rows: 4
- Resizable: Vertical only (`resize-y`)
- Minimum height: `100px`
- Maximum container height: `500px` with scroll
- Placeholder: "Type your message... (Click Send to submit)"
- MUST be disabled while a response is streaming

**Enter Key Behavior**:
- Pressing Enter MUST insert a newline (NOT submit the form)
- Shift+Enter, Ctrl+Enter, Meta+Enter MUST also insert a newline
- Form submission MUST only occur via the Send button click
- Implemented via `.PreventEnterSubmit` colocated hook

**Send Button**:
- Icon: `hero-paper-airplane` (normal state), `hero-arrow-path` with spin animation (loading state)
- Text: "Send" (normal), "Sending..." (loading)
- MUST be disabled during streaming
- MUST NOT submit empty or whitespace-only messages

**Form Validation**:
- Real-time validation via `phx-change="validate"` (updates form state as user types)
- On submit, message text is trimmed; empty strings are rejected silently

**Implementation Notes**:
- Form uses Phoenix form helpers with `to_form/1`
- Form ID: `chat-form`
- Input field name: `message`

---

## Message Streaming

### Streaming Architecture

**Requirement**: Message streaming MUST use a spawned process to avoid blocking the LiveView.

**Data Flow**:
1. User submits message via form (`handle_event("send", ...)`)
2. User message added to stream and message history
3. Empty assistant message placeholder added to stream (with `streaming: true`)
4. New process spawned to call `OllamaClient.chat_stream/3`
5. Streaming callback sends `{:stream_chunk, id, content}` to LiveView process
6. `handle_info({:stream_chunk, ...})` accumulates content and updates the stream
7. `{:stream_done, id}` finalizes the message (sets `streaming: false`)
8. Finalized message added to `message_history` for conversation context
9. On error, `{:stream_error, id, reason}` removes the failed message

### Message State

**Requirement**: Each message MUST have the following structure:

```elixir
%{
  id: "msg-<unique_integer>",   # Monotonic, positive integer
  role: "user" | "assistant",
  content: String.t(),
  timestamp: DateTime.t(),
  streaming: boolean()           # Only for assistant messages
}
```

**State Management**:

| Assign | Type | Purpose |
|--------|------|---------|
| `messages` | Phoenix stream | Rendered message list (UI) |
| `message_history` | List (stack) | Conversation context for API calls |
| `streaming_message` | String | Accumulator for current streaming response |
| `loading` | Boolean | Whether a response is being generated |
| `error` | String or nil | Current error message |
| `status_message` | String or nil | Informational status (e.g., recovery in progress) |
| `messages_empty?` | Boolean | Whether to show the empty state placeholder |

**Message History**:
- History is maintained as a stack (newest first) in `message_history`
- Before API calls, history is reversed and mapped to `%{role, content}` format
- Both user and finalized assistant messages are added to history
- History is cleared when the user clicks "Clear Chat"

### Conversation Context

**Requirement**: The full conversation history MUST be sent to Ollama with each request.

- All previous user and assistant messages MUST be included in the `messages` array
- Messages MUST be in chronological order (oldest first)
- Only `role` and `content` fields are sent to the API (not `id`, `timestamp`, or `streaming`)

---

## Model Management

### Model Listing

**Requirement**: The application MUST display available Ollama models for selection.

- On LiveView mount, the application MUST send `:load_models` message
- Models are fetched from `/api/tags` endpoint
- Model names are extracted from the response (`models[].name`)
- If no models are available or the request fails, the model selector MUST be hidden

### Model Selection

**Requirement**: Users MUST be able to switch between installed Ollama models.

- Model selector MUST be a dropdown (`<select>`) in the header area
- Changing the model fires `phx-change="select_model"` event
- Selected model MUST be used for all subsequent chat requests
- Model switching does NOT clear conversation history
- Default model: First model in the list returned by Ollama (overrides the configured default)

**Behavior on Mount**:
1. `selected_model` initialized from `OLLAMA_DEFAULT_MODEL` config (default: `"llama3"`)
2. When models are loaded, `selected_model` is overridden to `List.first(models)`
3. If model loading fails, the configured default remains

**Implementation Notes**:
- Model selector: `<select>` element with `phx-change="select_model"`
- Selected model stored in `socket.assigns.selected_model`

---

## Conversation Management

### Clear Chat

**Requirement**: Users MUST be able to clear the entire conversation.

- A trash icon button in the header triggers `phx-click="clear_chat"`
- Clearing MUST:
  - Reset the message stream (remove all messages from UI)
  - Clear `message_history` (reset conversation context)
  - Clear `streaming_message` accumulator
  - Clear any error or status messages
  - Set `messages_empty?` to `true` (show empty state)
- Clearing MUST NOT:
  - Change the selected model
  - Affect Ollama connection status
  - Require confirmation (immediate action)

### Message Identification

**Requirement**: Each message MUST have a unique identifier.

- IDs are generated using `System.unique_integer([:positive, :monotonic])`
- Format: `"msg-<integer>"` (e.g., `"msg-1"`, `"msg-2"`)
- IDs are used for Phoenix stream operations (insert, update, delete)

---

## Error Handling and Recovery

### Connection Error Detection

**Requirement**: The application MUST detect when Ollama is unreachable.

**Connection errors are identified by**:
- `Req.TransportError` with reason `:econnrefused` or `:timeout`
- Binary strings containing "connection refused", "econnrefused", or "timeout"
- Map values with `:reason` key matching `:econnrefused` or `:timeout`

**Implementation Notes**:
- Detection logic: `is_connection_error?/1` in `lib/ollama_chat_web/live/chat_live.ex:493`
- Handles multiple error shapes (struct, binary, map) for robustness

### Automatic Recovery

**Requirement**: When a connection error occurs during streaming, the application MUST attempt automatic recovery.

**Recovery Flow**:
1. Stream error detected as connection error
2. Failed assistant message removed from stream
3. Status message displayed: "Connection to Ollama lost. Attempting to reconnect..."
4. `{:attempt_recovery, message_id}` message sent to self
5. Recovery spawns a new process that calls `OllamaClient.ensure_ollama_running/0`
6. If Ollama is already running, recovery succeeds
7. If not running, `OLLAMA_START_COMMAND` is executed (if configured)
8. After startup, 3-second wait, then 2-second verification delay
9. Health check confirms Ollama is responding
10. On success: status updated to `:running`, status message cleared after 3 seconds
11. On failure: error message displayed to user

**Start Command Behavior**:
- Configured via `OLLAMA_START_COMMAND` environment variable
- Command executed via `System.cmd("sh", ["-c", command])`
- If not configured, recovery returns `{:error, "OLLAMA_START_COMMAND environment variable not set"}`
- Exit code 0 indicates successful start
- Non-zero exit code treated as failure with output included in error message

### Retry Logic

**Requirement**: The OllamaClient MUST retry requests after successfully starting Ollama.

- Both `chat/2` and `chat_stream/3` check for `econnrefused` errors
- On connection refusal, `ensure_ollama_running/0` is called
- If Ollama starts successfully, the original request is retried after 2-second delay
- If startup fails, the error propagates to the caller
- Only one retry attempt per request (no infinite retry loops within the client)

### Error Display

**Requirement**: Errors MUST be displayed to the user in a styled alert.

- Error messages displayed in a red-bordered alert box (`bg-red-900/50`, `border-red-500`)
- Includes exclamation triangle icon and "Error" heading
- Error text displayed below the heading
- Status messages (recovery in progress) displayed in a blue-bordered info box
- Error and status messages are mutually exclusive (setting one clears the other)

**Error Formatting**:
- `%{reason: :econnrefused}` → "Cannot connect to Ollama server"
- `%{reason: :timeout}` → "Connection to Ollama timed out"
- Binary strings → displayed as-is
- Other values → `"An error occurred: #{inspect(reason)}"`

---

## User Interface and Experience

### Visual Theme

**Requirement**: The application MUST use a dark gradient theme.

- Background: `bg-gradient-to-br from-slate-900 via-blue-900 to-slate-900`
- Max content width: `max-w-5xl` centered
- Padding: `px-4 py-8`

### Header

**Requirement**: The header MUST display the application title, connection status, model selector, and clear button.

**Layout**:
```
[Ollama Chat          ]  [Model: ▼ llama3]  [🗑]
[● Connected          ]
```

- Title: "Ollama Chat" in white, bold, `text-4xl`
- Status indicator: Colored dot (green=running with pulse, red=stopped, yellow=unknown)
- Status text: "Connected" or "Disconnected"
- Model selector: Dropdown with available models (hidden if none available)
- Clear button: Trash icon (`hero-trash`, `w-5 h-5`)

### Footer

**Requirement**: The footer MUST display attribution and current model information.

- Text: "Powered by Ollama - Model: {selected_model}"
- Model name highlighted in blue (`text-blue-400`)
- Centered, small text (`text-sm text-slate-400`)

### Responsive Design

**Requirement**: The application SHOULD be usable on both desktop and mobile viewports.

- Content container uses responsive max-width (`max-w-5xl`)
- Horizontal padding adapts to viewport
- Message bubbles limited to 80% width
- Textarea is resizable within constraints

### JavaScript Hooks

**Requirement**: Client-side behavior MUST be implemented via Phoenix LiveView colocated hooks.

**ScrollToBottom Hook**:
- Attached to the messages container (`phx-hook=".ScrollToBottom"`)
- Scrolls to bottom on `mounted()` and `updated()` events
- Implementation: `this.el.scrollTop = this.el.scrollHeight`

**PreventEnterSubmit Hook**:
- Attached to the textarea (`phx-hook=".PreventEnterSubmit"`)
- Listens for `keydown` events on the textarea
- If Enter is pressed without Shift/Ctrl/Meta modifiers, stops propagation
- This prevents the Phoenix form from submitting on Enter

**Implementation Notes**:
- Hooks are defined as colocated `<script>` tags in the `render/1` function of `chat_live.ex`
- Uses `Phoenix.LiveView.ColocatedHook` script type
- No external JavaScript files required for hook logic

---

## Configuration

### Environment Variables

**Requirement**: The application MUST be configurable via environment variables.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OLLAMA_BASE_URL` | No | `http://localhost:11434` | Ollama API base URL |
| `OLLAMA_DEFAULT_MODEL` | No | `llama3` | Default model to select |
| `OLLAMA_START_COMMAND` | No | _(none)_ | Shell command to start Ollama if not running |
| `OLLAMA_CHAT_PORT` | No | `4000` | HTTP server port |
| `SECRET_KEY_BASE` | Prod only | _(none)_ | Session encryption key (required in production) |
| `PHX_HOST` | Prod only | `example.com` | Production hostname |
| `PHX_SERVER` | Prod only | _(none)_ | Set to `true` to enable server in releases |
| `DNS_CLUSTER_QUERY` | No | _(none)_ | DNS query for distributed clustering |

**Implementation Notes**:
- All environment variables read in `config/runtime.exs`
- Ollama config stored in application env under `:ollama_chat` key
- Port configuration applied to endpoint HTTP settings
- `SECRET_KEY_BASE` is required in production (raises on missing)

### Development Configuration

**Requirement**: Development mode MUST provide a productive developer experience.

- Server binds to `127.0.0.1:4000` (localhost only)
- Code reloading enabled via `Phoenix.CodeReloader`
- Live reload watches for changes in templates, views, and assets
- esbuild and Tailwind run in watch mode
- LiveDashboard available at `/dev/dashboard`
- Swoosh mailbox preview at `/dev/mailbox`
- Debug errors enabled with detailed stack traces

### Production Configuration

**Requirement**: Production deployments MUST be secure and optimized.

- Force SSL with HSTS headers (localhost excluded for health checks)
- Static assets served with cache manifest (fingerprinted filenames)
- Assets minified via `mix assets.deploy`
- IPv6 enabled, binds on all interfaces
- Distributed clustering support via DNS

### Build Aliases

**Requirement**: Common development workflows MUST be available as Mix aliases.

| Alias | Commands | Purpose |
|-------|----------|---------|
| `mix setup` | `deps.get`, `assets.setup`, `assets.build` | Initial project setup |
| `mix assets.setup` | `tailwind.install`, `esbuild.install` | Install asset tools |
| `mix assets.build` | `compile`, `tailwind`, `esbuild` | Build all assets |
| `mix assets.deploy` | `tailwind --minify`, `esbuild --minify`, `phx.digest` | Production asset build |
| `mix precommit` | `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test` | Pre-commit quality checks |

---

## Security

### Session Management

**Requirement**: The application MUST use secure session management.

- Sessions stored in signed/encrypted cookies
- Session key: `_ollama_chat_key`
- Same-site policy: `Lax` (CSRF protection)
- CSRF protection enabled via `protect_from_forgery` plug

### No Authentication (Current)

**Requirement**: The current MVP does NOT implement authentication.

- The application is accessible to anyone who can reach the server
- All users share the same Ollama instance
- No user isolation or data separation
- Suitable for personal use or trusted network environments only

**Security Implications**:
- In development: Bound to localhost (`127.0.0.1`), safe by default
- In production: MUST be deployed behind a reverse proxy with authentication, or on a private network
- The `OLLAMA_START_COMMAND` executes shell commands — MUST NOT be user-controllable

### Content Security

**Requirement**: Standard Phoenix security headers MUST be applied.

- `put_secure_browser_headers` plug applied in browser pipeline
- No inline `<script>` tags except colocated hooks (which are compiled by Phoenix)
- No user-generated content rendered as raw HTML (messages use text interpolation)

### Ollama Start Command Security

**Requirement**: The Ollama start command MUST only be configurable by server operators.

- Command sourced exclusively from `OLLAMA_START_COMMAND` environment variable
- Not exposed in any UI or user-facing configuration
- Executed via `System.cmd("sh", ["-c", command])` with stderr redirected to stdout
- Server operators MUST ensure the command is safe and does not include untrusted input

---

## Testing

### Test Strategy

**Requirement**: The application SHOULD have tests covering core functionality.

**Test Structure**:

| Test File | Coverage |
|-----------|----------|
| `test/ollama_chat/ollama_client_test.exs` | OllamaClient API integration |
| `test/ollama_chat_web/live/chat_live_test.exs` | LiveView chat interface |
| `test/ollama_chat_web/controllers/error_html_test.exs` | HTML error rendering |
| `test/ollama_chat_web/controllers/error_json_test.exs` | JSON error rendering |

**Test Considerations**:
- Integration tests tagged with `@moduletag :integration` (require running Ollama)
- Some tests marked as `:skip` when dependent on specific model availability
- Tests should verify types and error conditions gracefully
- No database setup required (stateless application)

### Pre-Commit Workflow

**Requirement**: Developers MUST run quality checks before committing.

```bash
mix precommit
```

This runs:
1. `compile --warnings-as-errors` — Catch compiler warnings
2. `deps.unlock --unused` — Clean up unused dependencies
3. `format` — Enforce consistent code formatting
4. `test` — Run the full test suite

---

## Future Enhancements

This section documents planned features and open design questions. The application is intended for use by a small team.

### Conversation Persistence (Planned)

**Status**: Not implemented

**Description**: Save and load chat history across sessions so conversations survive page refreshes and server restarts.

**Requirements**:
- Conversations MUST be saved automatically (or on explicit save action)
- Users MUST be able to list, open, and delete saved conversations
- Each conversation MUST preserve the full message history and selected model
- Conversations SHOULD have titles (auto-generated from first message or user-defined)

**Storage Options Under Consideration**:

**Option A: SQLite (via Ecto.SQLite3)**
- Pro: Zero external dependencies, embedded database
- Pro: Simple deployment (single file)
- Con: Limited concurrent write performance
- Con: Less suitable for multi-user scenarios

**Option B: PostgreSQL (via Ecto)**
- Pro: Battle-tested with Phoenix, excellent concurrent access
- Pro: Supports full-text search, JSONB for flexible metadata
- Pro: Better for multi-user/team scenarios
- Con: Requires external database service
- Con: More complex deployment

**Option C: File-Based (JSON)**
- Pro: Simplest implementation, human-readable files
- Pro: Easy backup and portability
- Con: No query capabilities
- Con: Concurrency issues with file locking
- Con: Performance degrades with many conversations

**Data Model (Preliminary)**:
```
conversations
├── id (UUID)
├── title (string)
├── model (string, Ollama model used)
├── messages (JSON array of {role, content, timestamp})
├── created_at (datetime)
├── updated_at (datetime)
└── user_id (optional, for future multi-user support)
```

**Open Questions**:
- Should conversations auto-save on every message or require explicit save?
- What is the retention policy for old conversations?
- Should conversation titles be auto-generated from the first user message?

### Multiple Concurrent Chats (Planned)

**Status**: Not implemented

**Description**: Support multiple chat tabs or conversations simultaneously, allowing users to work on different topics in parallel.

**Requirements**:
- Users MUST be able to create new chat sessions without losing the current one
- Users MUST be able to switch between active conversations
- Each conversation MUST have independent message history and model selection
- Inactive conversations MUST NOT consume streaming resources

**UI Options Under Consideration**:

**Option A: Tab Bar**
- Horizontal tabs above the chat area
- New tab button (+) creates a fresh conversation
- Tabs show conversation title or "New Chat"

**Option B: Sidebar Conversation List**
- Persistent sidebar listing all conversations
- Current conversation highlighted
- Collapsible for more chat space

**Open Questions**:
- Should multiple conversations be able to stream simultaneously?
- How many concurrent conversations should be supported?
- Should conversations be reorderable or pinnable?

### Markdown Rendering (Planned)

**Status**: Not implemented — messages currently displayed as plain text with `whitespace-pre-wrap`

**Description**: Render LLM responses as formatted markdown with syntax highlighting, enabling rich display of code blocks, lists, tables, and other markdown elements.

**Requirements**:
- Assistant messages MUST render markdown to styled HTML
- Code blocks MUST have syntax highlighting with language detection
- Inline code, bold, italic, links, and lists MUST render correctly
- User messages MAY remain as plain text (or optionally render markdown)
- Markdown rendering MUST work correctly during streaming (partial content)
- Copy button SHOULD be available on code blocks

**Technical Considerations**:
- Server-side rendering via `Earmark` or `MDEx` (Elixir markdown libraries)
- Client-side rendering via JavaScript (e.g., `marked` + `highlight.js`)
- Streaming complicates server-side rendering (incomplete markdown during stream)
- XSS prevention: Rendered HTML MUST be sanitized to prevent script injection

**Open Questions**:
- Should rendering happen server-side or client-side?
- How to handle incomplete markdown during streaming (e.g., unclosed code block)?
- Should LaTeX/math rendering be supported?

### Authentication and Multi-User Support (Under Consideration)

**Status**: Not started

**Description**: Add user authentication to support team use with isolated conversations.

**Requirements**:
- Users MUST authenticate before accessing the chat interface
- Each user's conversations MUST be isolated from other users
- Shared Ollama instance, but separate conversation history

**Options**:

**Option A: Phoenix Authentication (phx.gen.auth)**
- Pro: Built-in Phoenix generator, well-maintained
- Pro: Email/password with session-based auth
- Con: Requires database for user storage

**Option B: Basic HTTP Authentication**
- Pro: Simple, no database required
- Pro: Can be configured at reverse proxy level
- Con: Poor user experience
- Con: No user-specific features

**Option C: OAuth/SSO Integration**
- Pro: Integrates with existing team identity providers
- Pro: No password management
- Con: More complex setup
- Con: Requires external identity provider

**Open Questions**:
- Is authentication needed for the team use case, or is network-level access control sufficient?
- Should there be admin/user role separation?

### System Prompt Configuration (Under Consideration)

**Status**: Not implemented

**Description**: Allow users to configure a system prompt that is prepended to every conversation.

**Requirements**:
- System prompt MAY be configurable per conversation or globally
- System prompt MUST be sent as the first message with `role: "system"` in the API request
- System prompt changes SHOULD take effect on the next message (not retroactively)

### Response Formatting Options (Under Consideration)

**Status**: Not implemented

**Description**: Allow users to control Ollama generation parameters.

**Potential Parameters**:
- Temperature (creativity vs. determinism)
- Max tokens (response length limit)
- Top-p / Top-k (sampling strategies)
- Context window size

### Conversation Export (Under Consideration)

**Status**: Not implemented

**Description**: Export conversations in portable formats.

**Potential Formats**:
- Markdown file (messages as blockquotes or headers)
- JSON (raw conversation data)
- PDF (formatted conversation)

---

## Routing

### Route Structure

**Requirement**: The application MUST use a minimal routing structure.

| Path | Handler | Description |
|------|---------|-------------|
| `/` | `ChatLive` (`:index` action) | Main chat interface |
| `/dev/dashboard` | LiveDashboard | Monitoring (dev only) |
| `/dev/mailbox` | Swoosh preview | Email preview (dev only) |

### Request Pipeline

**Requirement**: All browser requests MUST pass through the standard Phoenix pipeline.

```
HTTP Request
  → Plug.Static (serve static assets)
  → Plug.Parsers (parse request body)
  → Plug.Session (cookie-based sessions)
  → Router → Browser Pipeline
    → :accepts ["html"]
    → :fetch_session
    → :fetch_live_flash
    → :put_root_layout
    → :protect_from_forgery
    → :put_secure_browser_headers
  → ChatLive (LiveView via WebSocket)
```

### WebSocket Connection

**Requirement**: LiveView MUST operate over a persistent WebSocket connection.

- WebSocket path: `/live`
- Signed with CSRF token for security
- Long-poll fallback after 2.5 seconds if WebSocket unavailable

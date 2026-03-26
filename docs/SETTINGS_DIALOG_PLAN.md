# Settings Dialog & MCP Server Configuration Plan

> **Status:** Phase 1 ✅ Complete | Phase 2 ✅ Complete | Phase 3 ✅ Complete | Phase 4 🔲 Future

## Overview

Move settings from sidebar accordion panels into a proper tabbed settings dialog, and add the ability to configure MCP servers from the UI at runtime.

## Current State

### Settings in Sidebar (Accordion Panels)
- **System Prompt** (L1376–L1408) — toggle open/close, textarea
- **Storage Settings** (L1411–L1446) — toggle, checkbox for save intermediate events
- **MCP Tools** (L1450–L1533) — toggle, view-only server status & tool list
- **Generation Parameters** (L1537–L1682) — toggle, 5 range sliders + reset button

### MCP Server Configuration
- Configured entirely via Elixir config files (`config/dev.exs`)
- No way to add, edit, or remove servers from the UI
- `MCPClient` GenServer reads `Application.get_env(:ollama_chat, :mcp_servers)` at startup
- No dynamic management API exists

### Persistence Model
- No database — state lives in-memory and browser localStorage
- Client state: `localStorage` via JS hooks (model selection, conversations, preferences)
- Server-side config: environment variables and Elixir config files

---

## Design Decisions

### Sidebar vs. Dialog Placement

| **Keep in Sidebar** (frequent/contextual) | **Move to Settings Dialog** (configure once) |
|---|---|
| Model selector | System Prompt |
| Conversations list | Generation Parameters |
| Ollama status + Start/Restart/Kill | Storage Settings |
| Health check indicator | MCP Server Configuration (new) |
| Export / Clear buttons | MCP Tools reference view |

### Settings Dialog Structure

**Tabbed modal with three tabs:**

1. **General** — System prompt, storage settings (save intermediate events)
2. **Generation** — Temperature, Max Tokens, Top P, Top K, Context Window, Reset
3. **MCP Servers** — Server list with add/edit/remove/toggle, tool viewer per server

### MCP Server Persistence

MCP servers are server-side processes, so config must live server-side:

- New `OllamaChat.MCPConfig` module reads/writes JSON file
- Default path: `~/.config/ollama_chat/mcp_servers.json`
- On startup: merge file-based user config with Elixir app config (app config = defaults)
- UI changes write to JSON file AND dynamically update `MCPClient` GenServer

**Config format** (inspired by Claude's `claude_desktop_config.json`):

```json
{
  "servers": [
    {
      "name": "mcp_filesystem",
      "display_name": "MCP Filesystem",
      "description": "File operations within the MCP workspace",
      "command": "/path/to/mcpctl",
      "args": ["filesystem"],
      "enabled": true,
      "requires_approval": false,
      "dangerous_tools": ["write_file", "delete_file"],
      "env": {}
    }
  ]
}
```

---

## Phase 1: Settings Dialog Infrastructure ✅

**Goal:** Create the modal, move existing settings into it, add gear button to sidebar.
**Completed:** Commit `30274ce`

### 1.1 — Settings Modal Component

- Inline section in `render/1` (following current project pattern — no separate component files)
- Full-screen overlay with backdrop blur (similar to existing tool approval modal at L1949–L1996)
- Tabbed navigation: General | Generation | MCP Servers
- Smooth open/close with `@show_settings` assign
- New event handlers: `"open_settings"`, `"close_settings"`, `"switch_settings_tab"`
- New assigns: `@show_settings` (boolean), `@settings_tab` (`:general` | `:generation` | `:mcp`)

### 1.2 — Move Existing Settings

- **System Prompt**: Move textarea from sidebar into General tab
- **Storage Settings**: Move checkbox from sidebar into General tab
- **Generation Parameters**: Move sliders from sidebar into Generation tab
- **MCP Tools view**: Move from sidebar into MCP Servers tab (read-only for now)
- All existing event handlers remain — only the render location changes

### 1.3 — Sidebar Cleanup

- Replace removed accordion panels with a single **⚙ Settings** button
- Add summary badges on settings button (e.g., "Custom" if system prompt active or generation params modified)
- Sidebar becomes: Header/Status → Model → Health → Conversations → Export/Clear → **⚙ Settings** → Footer

### 1.4 — Tests

- LiveView test: settings dialog opens/closes
- LiveView test: tab switching works
- LiveView test: existing settings interactions still work through the dialog

### Files Changed (Phase 1)

| File | Changes |
|---|---|
| `lib/ollama_chat_web/live/chat_live.ex` | Add settings dialog render, move settings sections, new assigns/events |
| `test/ollama_chat_web/live/chat_live_test.exs` | Add settings dialog tests |

---

## Phase 2: MCP Server Configuration Backend ✅

**Goal:** Enable runtime MCP server management with file-based persistence.
**Completed:** See commit history.

### 2.1 — `OllamaChat.MCPConfig` Module

New file: `lib/ollama_chat/mcp_config.ex` ✅

- `config_path/0` — returns path from app env or default `~/.config/ollama_chat/mcp_servers.json`
- `load/0` — reads JSON file, returns `{:ok, list}` or `{:ok, []}` if file doesn't exist, `{:error, reason}` on parse failure
- `save/1` — writes server configs to JSON file (atomic write with temp file + rename)
- `load_with_defaults/0` — merges file config with `Application.get_env(:ollama_chat, :mcp_servers, [])`, file config wins for matching names
- `validate_server_config/1` — ensures required fields (name, display_name, command), validates types, fills defaults
- `to_internal/1` / `to_json/1` — conversion between string-keyed JSON maps and atom-keyed internal maps

### 2.2 — MCPClient Dynamic Management ✅

Extended `lib/ollama_chat/mcp_client.ex` with new public API:

- `add_server(config)` — validates, persists, starts if enabled. Returns `:ok | {:error, reason}`
- `remove_server(name)` — stops server, unlinks, removes tools, persists. Returns `:ok | {:error, reason}`
- `update_server(name, config)` — stops old, validates new, starts if enabled, persists. Returns `:ok | {:error, reason}`
- `toggle_server(name, enabled)` — enables/disables, starts/stops accordingly, persists. Returns `:ok | {:error, reason}`
- `list_server_configs/0` — returns current server configs from GenServer state

Additional changes:
- `State` struct now includes `server_configs` field
- `init/1` always traps exits (supports dynamic server management when MCP starts disabled)
- `handle_info(:start_servers, ...)` and `handle_info({:restart_server, ...}, ...)` use `state.server_configs` instead of `Application.get_env`
- Startup loads configs via `MCPConfig.load_with_defaults/0`
- Extracted `maybe_start_server/2`, `start_and_link_server/2`, `stop_and_remove_client/2`, `cancel_and_remove_timer/2`, `replace_config/3`, `persist_configs/1` helpers

### 2.3 — Config Wiring ✅

| File | Changes |
|---|---|
| `config/config.exs` | Added `mcp_config_path: nil` default |
| `config/runtime.exs` | Wired `MCP_CONFIG_PATH` env var |
| `CLAUDE.md` | Updated key modules and env var list |

### 2.4 — Tests ✅

- **35 MCPConfig tests:** config_path, load, save, validate, to_internal/to_json, load_with_defaults, save+load round-trip
- **16 MCPClient dynamic management tests:** add (valid/invalid/duplicate/disabled), remove (existing/nonexistent/string-name), update (existing/nonexistent/invalid), toggle (enable/disable/nonexistent), list_server_configs, persistence verification
- **Total:** 269 tests pass, 0 failures, 0 compile warnings, 0 Credo issues

### Files Changed (Phase 2)

| File | Changes |
|---|---|
| `lib/ollama_chat/mcp_config.ex` | **New** — JSON file persistence (config_path, load, save, validate, merge, convert) |
| `lib/ollama_chat/mcp_client.ex` | Dynamic management API (add/remove/update/toggle/list), MCPConfig integration, extracted helpers |
| `config/config.exs` | Added `mcp_config_path: nil` |
| `config/runtime.exs` | Wired `MCP_CONFIG_PATH` env var |
| `CLAUDE.md` | Added MCPClient and MCPConfig to key modules |
| `test/ollama_chat/mcp_config_test.exs` | **New** — 35 tests |
| `test/ollama_chat/mcp_client_test.exs` | Added 17 dynamic management tests |

---

## Phase 3: MCP Server Configuration UI ✅

**Goal:** Build the interactive MCP server management interface in the Settings dialog.
**Completed:** See commit history.

### 3.1 — MCP Servers Tab Layout ✅

Two-mode UI in the MCP Servers tab:

**List mode** (when `@editing_mcp_server` is nil):
- Server cards with status indicator (●), display name, description, command preview
- Enable/disable toggle button per server (hero-signal / hero-signal-slash icons)
- Edit button per server (hero-pencil-square icon)
- "Add Server" button at top
- Available Tools section below with tool name, description, server, approval badge

**Edit mode** (when `@editing_mcp_server` is set):
- Form fields: Server Name, Display Name, Description, Command, Args (one per line textarea)
- Checkboxes: Enabled, Require Approval for All Tools (with hidden inputs for false values)
- Dangerous Tools: comma-separated text input
- Save, Cancel, and Delete buttons (Delete only shown for existing servers, with confirmation)
- Inline error banner for validation failures

### 3.2 — Event Handlers ✅

- `"add_mcp_server"` — initializes empty form data, sets `@editing_mcp_server`
- `"edit_mcp_server"` — loads existing server config into form data
- `"cancel_edit_mcp_server"` — clears editing state
- `"save_mcp_server"` — parses form (args by newline, dangerous_tools by comma), checks MCPClient state to determine add vs update, calls `MCPClient.add_server/1` or `MCPClient.update_server/2`
- `"delete_mcp_server"` — calls `MCPClient.remove_server/1` with confirmation dialog
- `"toggle_mcp_server_enabled"` — calls `MCPClient.toggle_server/2`, refreshes configs/status/tools

### 3.3 — New Assigns ✅

- `@mcp_server_configs` — list of all server configs (loaded from MCPClient on settings open)
- `@editing_mcp_server` — `nil` or string-keyed map of form data being edited
- `@mcp_form_error` — `nil` or error string to display in error banner

### 3.4 — Tests ✅

- 11 new LiveView tests covering: MCP disabled state, add/cancel/save/delete/toggle/edit flows, validation errors, args/dangerous_tools parsing, update existing server
- **Total:** 280 tests pass, 0 failures, 0 compile warnings, 0 Credo issues

### 3.5 — Bug Fixes During Implementation

- Fixed `String.to_existing_atom` → `String.to_atom` in edit/delete/toggle handlers (prevents crash on unknown server names)
- Fixed `runtime.exs` overriding `mcp_config_path` with `nil` when `MCP_CONFIG_PATH` env var not set (broke test config isolation)
- Fixed `MCPConfig.config_path/0` to use `||` instead of `Application.get_env/3` default (handles explicit `nil` values)
- Fixed `save_mcp_server` to check `MCPClient.list_server_configs()` instead of local assigns for add-vs-update determination (assigns may be stale when MCP is disabled)
- Added `mcp_config_path` to `config/test.exs` pointing to temp directory

### Files Changed (Phase 3)

| File | Changes |
|---|---|
| `lib/ollama_chat_web/live/chat_live.ex` | New assigns, 6 event handlers, `fetch_mcp_tools/0` helper, full MCP tab UI replacement |
| `lib/ollama_chat/mcp_config.ex` | Fixed `config_path/0` nil handling |
| `config/runtime.exs` | Fixed `mcp_config_path` nil override |
| `config/test.exs` | Added `mcp_config_path` for test isolation |
| `test/ollama_chat_web/live/chat_live_test.exs` | 11 new MCP server management tests |

---

## Phase 4: Polish & Edge Cases

**Goal:** Production-quality UX.

### 4.1 — Keyboard & Accessibility
- Escape closes settings dialog
- Tab/Shift+Tab navigation within dialog
- Focus trap inside modal
- ARIA attributes on modal, tabs, forms

### 4.2 — Transitions & Micro-interactions
- Smooth fade-in/slide for dialog open
- Tab switch animation
- Server status transitions (connecting → connected)
- Toast/flash for save confirmation

### 4.3 — Settings Import/Export (nice-to-have)
- Export all settings as JSON (system prompt, generation params, MCP servers)
- Import from JSON file
- Useful for sharing configurations

### 4.4 — Validation & Error Handling
- Command path validation (file exists, is executable)
- Connection test before saving server
- Graceful handling when JSON config file is corrupted
- Warning when removing a server that has in-flight tool calls

---

## Full File Change Summary

| File | Phase | Changes |
|---|---|---|
| `lib/ollama_chat_web/live/chat_live.ex` | 1, 3 | Settings dialog, move settings, MCP server UI |
| `lib/ollama_chat/mcp_config.ex` | 2 | **New** — JSON file persistence |
| `lib/ollama_chat/mcp_client.ex` | 2 | Dynamic server management API |
| `lib/ollama_chat/application.ex` | 2 | Start MCPConfig if needed |
| `config/config.exs` | 2 | Add `mcp_config_path` option |
| `config/dev.exs` | 2 | Optionally set dev config path |
| `config/runtime.exs` | 2 | Wire `MCP_CONFIG_PATH` env var |
| `test/ollama_chat/mcp_config_test.exs` | 2 | **New** — MCPConfig tests |
| `test/ollama_chat/mcp_client_test.exs` | 2 | Dynamic management tests |
| `test/ollama_chat_web/live/chat_live_test.exs` | 1, 3 | Settings dialog + MCP UI tests |

## Estimated Effort

| Phase | Scope | Estimate | Actual |
|---|---|---|---|
| Phase 1 | Settings dialog + move existing settings | 3–4 hours | ✅ Done |
| Phase 2 | MCP Config backend + MCPClient dynamic API | 2–3 hours | ✅ Done |
| Phase 3 | MCP Server configuration UI | 3–4 hours | ✅ Done |
| Phase 4 | Polish, accessibility, edge cases | 2–3 hours | 🔲 Future |

## Execution Order

1. **Phase 1** first — self-contained, immediately improves UI, no backend changes
2. **Phase 2** next — builds backend API that Phase 3 depends on
3. **Phase 3** once Phase 2 is solid — wires UI to backend
4. **Phase 4** throughout — polish incrementally

## Principles (from project conventions)

- **Never Swallow Errors** — Log/re-raise/report every error with full context
- **Test Driven Development** — Write tests covering happy paths, error paths, edge cases
- **Commit and Push After Successful Completion** — Commit at each milestone
- **World-class UI** — Subtle micro-interactions, clean typography, delightful details (per AGENTS.md)
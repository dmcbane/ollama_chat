# Settings Dialog & MCP Server Configuration Plan

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

## Phase 1: Settings Dialog Infrastructure

**Goal:** Create the modal, move existing settings into it, add gear button to sidebar.

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

## Phase 2: MCP Server Configuration Backend

**Goal:** Enable runtime MCP server management with file-based persistence.

### 2.1 — `OllamaChat.MCPConfig` Module

New file: `lib/ollama_chat/mcp_config.ex`

- `config_path/0` — returns path from app env or default `~/.config/ollama_chat/mcp_servers.json`
- `load/0` — reads JSON file, returns list of server configs; returns `[]` if file doesn't exist
- `save/1` — writes server configs to JSON file (atomic write with temp file + rename)
- `merge_with_defaults/1` — merges file config with `Application.get_env(:ollama_chat, :mcp_servers, [])`, file config wins for matching names
- `validate_server_config/1` — ensures required fields (name, command), validates name format

### 2.2 — MCPClient Dynamic Management

Extend `lib/ollama_chat/mcp_client.ex` with new public API:

- `add_server(config)` — start a new server, update state, return `:ok | {:error, reason}`
- `remove_server(name)` — stop server, unlink, clean up tools, return `:ok`
- `update_server(name, config)` — stop old, start new if config changed, return `:ok | {:error, reason}`
- `toggle_server(name, enabled)` — enable/disable without removing config
- `list_server_configs/0` — return current server configs (for UI to display)

Modify `handle_info(:start_servers, ...)` and `handle_info({:restart_server, ...}, ...)` to use `MCPConfig.load()` merged with app config instead of only `Application.get_env`.

### 2.3 — Config Wiring

| File | Changes |
|---|---|
| `config/config.exs` | Add `mcp_config_path` option |
| `config/dev.exs` | Optionally set dev config path |
| `config/runtime.exs` | Wire `MCP_CONFIG_PATH` env var |

### 2.4 — Tests

- `MCPConfig` unit tests: load/save/merge/validate
- `MCPClient` tests: add_server, remove_server, toggle_server
- Integration test: add server via config → tools become available

### Files Changed (Phase 2)

| File | Changes |
|---|---|
| `lib/ollama_chat/mcp_config.ex` | **New** — JSON file persistence for MCP server configs |
| `lib/ollama_chat/mcp_client.ex` | Add dynamic server management API |
| `config/config.exs` | Add `mcp_config_path` option |
| `config/dev.exs` | Optionally set dev config path |
| `config/runtime.exs` | Wire `MCP_CONFIG_PATH` env var |
| `test/ollama_chat/mcp_config_test.exs` | **New** — MCPConfig tests |
| `test/ollama_chat/mcp_client_test.exs` | Add dynamic management tests |

---

## Phase 3: MCP Server Configuration UI

**Goal:** Build the interactive MCP server management interface in the Settings dialog.

### 3.1 — MCP Servers Tab Layout

**A. Server List:**
- Card per server: name, description, status indicator (●), tool count, enabled toggle
- Click card to select/expand details
- "Add Server" button at bottom

**B. Server Detail / Edit Form:**
- Fields: Display Name, Description, Command, Args (one per line), Environment Variables (key=value)
- Checkboxes: Enabled, Requires Approval
- Dangerous Tools: tag input from discovered tools
- "Save" and "Delete" buttons with validation errors inline

**C. Tools Panel:**
- Expandable list of tools for the selected server
- Tool name, description, input schema summary
- "Requires approval" badge

### 3.2 — Event Handlers

- `"add_mcp_server"` — opens blank form
- `"edit_mcp_server"` / `"select_mcp_server"` — opens form with existing data
- `"save_mcp_server"` — validates, calls `MCPConfig.save/1` + `MCPClient.add_server/1` or `update_server/2`
- `"delete_mcp_server"` — confirmation, calls `MCPConfig.save/1` + `MCPClient.remove_server/1`
- `"toggle_mcp_server"` — calls `MCPClient.toggle_server/2` + persists
- `"test_mcp_server"` — attempts to connect and list tools (nice-to-have)

### 3.3 — New Assigns

- `@editing_mcp_server` — `nil` or server config map being edited
- `@mcp_server_form` — form data for the server editor
- `@selected_mcp_server` — atom name of selected server for detail view
- `@mcp_server_configs` — list of all configs (from MCPConfig + MCPClient)

### 3.4 — Tests

- LiveView tests: add/edit/delete server through UI
- LiveView test: toggle server enabled/disabled
- LiveView test: validation errors display

### Files Changed (Phase 3)

| File | Changes |
|---|---|
| `lib/ollama_chat_web/live/chat_live.ex` | MCP server management UI + event handlers |
| `test/ollama_chat_web/live/chat_live_test.exs` | MCP server UI tests |

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

| Phase | Scope | Estimate |
|---|---|---|
| Phase 1 | Settings dialog + move existing settings | 3–4 hours |
| Phase 2 | MCP Config backend + MCPClient dynamic API | 2–3 hours |
| Phase 3 | MCP Server configuration UI | 3–4 hours |
| Phase 4 | Polish, accessibility, edge cases | 2–3 hours |
| **Total** | | **10–14 hours** |

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
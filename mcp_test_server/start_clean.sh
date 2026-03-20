#!/usr/bin/env bash
# MCP Server management script
#
# DIRECT STDIO TRANSPORT  (used in MCP client config — stdout stays clean JSON-RPC)
#   ./start_clean.sh [filesystem|memory|system|web]
#
# BACKGROUND MANAGEMENT
#   ./start_clean.sh status                   show all servers
#   ./start_clean.sh start  <server|all>      start in background
#   ./start_clean.sh stop   <server|all>      stop background instance
#   ./start_clean.sh restart <server|all>     stop then start
#
# SERVERS
#   filesystem  17 file operation tools (default)
#   memory       4 in-memory KV store tools
#   system      12 BEAM monitoring, env, and utility tools
#   web          1 web search tool (DuckDuckGo)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

ALL_SERVERS="filesystem memory system web"
PID_DIR="$SCRIPT_DIR/.pids"
LOG_DIR="$SCRIPT_DIR/.logs"
FIFO_DIR="$SCRIPT_DIR/.fifos"

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────

pid_file()  { printf "%s/mcp-%s.pid"  "$PID_DIR"  "$1"; }
log_file()  { printf "%s/mcp-%s.log"  "$LOG_DIR"  "$1"; }
fifo_file() { printf "%s/mcp-%s.fifo" "$FIFO_DIR" "$1"; }

is_running() {
  local pid_f
  pid_f="$(pid_file "$1")"
  [ -f "$pid_f" ] && kill -0 "$(cat "$pid_f")" 2>/dev/null
}

server_pid() {
  local pid_f
  pid_f="$(pid_file "$1")"
  [ -f "$pid_f" ] && cat "$pid_f" || echo "-"
}

validate_server() {
  case "$1" in
    filesystem|memory|system|web|all) return 0 ;;
    *)
      printf "${RED}Error:${NC} Unknown server '%s'.\n" "$1" >&2
      printf "Valid servers: filesystem  memory  system  web  all\n" >&2
      return 1
      ;;
  esac
}

resolve_servers() {
  if [ "$1" = "all" ]; then echo "$ALL_SERVERS"; else echo "$1"; fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_status() {
  echo ""
  printf "${BOLD}%-16s %-10s %-8s %s${NC}\n" "SERVER" "STATUS" "PID" "LOG"
  printf "%-16s %-10s %-8s %s\n"             "----------------" "----------" "--------" "-------------------------------"

  for server in $ALL_SERVERS; do
    if is_running "$server"; then
      pid="$(server_pid "$server")"
      log_f="$(log_file "$server")"
      log_size=""
      if [ -f "$log_f" ]; then
        log_size="$(wc -c < "$log_f" | tr -d ' ')b"
      fi
      printf "${GREEN}%-16s %-10s${NC} %-8s .logs/mcp-%s.log (%s)\n" \
        "$server" "running" "$pid" "$server" "$log_size"
    else
      printf "${YELLOW}%-16s${NC} %-10s\n" "$server" "stopped"
      # Clean up stale pid/fifo files
      rm -f "$(pid_file "$server")" "$(fifo_file "$server")"
    fi
  done
  echo ""
}

cmd_start() {
  local target="${1:-filesystem}"
  validate_server "$target" || return 1

  mkdir -p "$PID_DIR" "$LOG_DIR" "$FIFO_DIR"

  # Compile once before starting any servers (output to stderr)
  printf "${CYAN}Compiling...${NC}\n" >&2
  mix compile >&2

  for server in $(resolve_servers "$target"); do
    local log_f pid_f fifo_f
    log_f="$(log_file "$server")"
    pid_f="$(pid_file "$server")"
    fifo_f="$(fifo_file "$server")"

    if is_running "$server"; then
      printf "  ${YELLOW}%-12s${NC} already running (PID %s)\n" "$server" "$(server_pid "$server")"
      continue
    fi

    # Named FIFO keeps stdin open so the server never receives EOF while idle.
    # tail -f blocks on the FIFO and forwards any bytes written to it as stdin
    # to the mix process, letting you send JSON-RPC test messages manually.
    [ -p "$fifo_f" ] || mkfifo "$fifo_f"

    tail -f "$fifo_f" \
      | MCP_SERVER="$server" mix run --no-halt >> "$log_f" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$pid_f"

    printf "  ${GREEN}✓ %-12s${NC} started  PID=%-6s  log=.logs/mcp-%s.log\n" \
      "$server" "$new_pid" "$server"
  done
}

cmd_stop() {
  local target="${1:-all}"
  validate_server "$target" || return 1

  for server in $(resolve_servers "$target"); do
    local pid_f fifo_f
    pid_f="$(pid_file "$server")"
    fifo_f="$(fifo_file "$server")"

    if is_running "$server"; then
      local pid
      pid="$(cat "$pid_f")"

      # Terminate the mix run process; the broken pipe will kill tail shortly after
      kill "$pid" 2>/dev/null || true

      # Give the process a moment; escalate to KILL if needed
      local waited=0
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
        sleep 1
        waited=$((waited + 1))
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true

      # Clean up the tail process that owned the FIFO read-end
      pkill -f "tail.*$(basename "$fifo_f")" 2>/dev/null || true

      rm -f "$pid_f" "$fifo_f"
      printf "  ${GREEN}✓ %-12s${NC} stopped\n" "$server"
    else
      printf "  ${YELLOW}%-12s${NC} not running\n" "$server"
      rm -f "$pid_f" "$fifo_f"
    fi
  done
}

cmd_restart() {
  local target="${1:-all}"
  validate_server "$target" || return 1
  cmd_stop "$target"
  sleep 1
  cmd_start "$target"
}

# ── Main dispatch ─────────────────────────────────────────────────────────────

COMMAND="${1:-}"

case "$COMMAND" in

  status)
    cmd_status
    ;;

  start)
    cmd_start "${2:-filesystem}"
    ;;

  stop)
    cmd_stop "${2:-all}"
    ;;

  restart)
    cmd_restart "${2:-all}"
    ;;

  filesystem|memory|system|web|"")
    # ── Direct stdio transport mode ───────────────────────────────────────────
    # This path is used when an MCP client (e.g. Claude Desktop) invokes this
    # script as a subprocess. stdout must carry only JSON-RPC messages; all
    # other output (compiler, startup logs) is redirected to stderr.
    SERVER="${COMMAND:-filesystem}"
    mix compile >&2
    exec env MCP_SERVER="$SERVER" mix run --no-halt
    ;;

  -h|--help|help)
    echo ""
    echo "  ${BOLD}MCP Server Manager${NC}"
    echo ""
    printf "  ${BOLD}Management commands:${NC}\n"
    printf "    %-38s %s\n" "./start_clean.sh status"            "show status of all servers"
    printf "    %-38s %s\n" "./start_clean.sh start  [server|all]" "start in background"
    printf "    %-38s %s\n" "./start_clean.sh stop   [server|all]" "stop background instance"
    printf "    %-38s %s\n" "./start_clean.sh restart [server|all]" "stop then start"
    echo ""
    printf "  ${BOLD}Direct stdio transport (for MCP client config):${NC}\n"
    printf "    %-38s %s\n" "./start_clean.sh [server]" "stdout = JSON-RPC only"
    echo ""
    printf "  ${BOLD}Servers:${NC}  filesystem  memory  system  web\n"
    echo ""
    ;;

  *)
    printf "${RED}Error:${NC} Unknown command or server: '%s'\n\n" "$COMMAND" >&2
    printf "Run '%s help' for usage.\n" "$0" >&2
    exit 1
    ;;

esac

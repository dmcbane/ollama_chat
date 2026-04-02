#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL Docker/Podman container lifecycle management for Ollama Chat
# Usage: scripts/postgres-docker.sh <command> [options]

# ---------------------------------------------------------------------------
# Default configuration (override via environment variables)
# ---------------------------------------------------------------------------
OLLAMA_CHAT_DB_USERNAME="${OLLAMA_CHAT_DB_USERNAME:-ollama_chat}"
OLLAMA_CHAT_DB_PASSWORD="${OLLAMA_CHAT_DB_PASSWORD:-ollama_chat}"
OLLAMA_CHAT_DB_NAME="${OLLAMA_CHAT_DB_NAME:-ollama_chat_dev}"
OLLAMA_CHAT_DB_PORT="${OLLAMA_CHAT_DB_PORT:-5432}"
OLLAMA_CHAT_POSTGRES_DATA_DIR="${OLLAMA_CHAT_POSTGRES_DATA_DIR:-./priv/postgres_data}"
CONTAINER_NAME="${CONTAINER_NAME:-ollama-chat-postgres}"
IMAGE_NAME="${IMAGE_NAME:-ollama-chat-postgres:latest}"

# ---------------------------------------------------------------------------
# Auto-detect container runtime (docker vs podman)
# ---------------------------------------------------------------------------
detect_runtime() {
  if command -v podman &>/dev/null; then
    RUNTIME="podman"
  elif command -v docker &>/dev/null; then
    RUNTIME="docker"
  else
    log_err "Neither docker nor podman found in PATH"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Colored output helpers
# ---------------------------------------------------------------------------
log_info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

log_ok() {
  printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"
}

log_err() {
  printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Resolve the project root (where Dockerfile.postgres lives)
# ---------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Helper: check if the container exists (any state)
# ---------------------------------------------------------------------------
container_exists() {
  $RUNTIME container inspect "$CONTAINER_NAME" &>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: check if the container is running
# ---------------------------------------------------------------------------
container_running() {
  [ "$($RUNTIME container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

# ---------------------------------------------------------------------------
# Helper: check if the image exists locally
# ---------------------------------------------------------------------------
image_exists() {
  $RUNTIME image inspect "$IMAGE_NAME" &>/dev/null
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_build() {
  log_info "Building image $IMAGE_NAME with $RUNTIME ..."
  $RUNTIME build \
    -t "$IMAGE_NAME" \
    -f "$PROJECT_ROOT/Dockerfile.postgres" \
    "$PROJECT_ROOT"
  log_ok "Image $IMAGE_NAME built successfully"
}

cmd_start() {
  # Build image first if it doesn't exist
  if ! image_exists; then
    log_info "Image $IMAGE_NAME not found locally — building first"
    cmd_build
  fi

  # If the container already exists, restart it if stopped or report running
  if container_exists; then
    if container_running; then
      log_ok "Container $CONTAINER_NAME is already running"
      return 0
    else
      log_info "Container $CONTAINER_NAME exists but is stopped — restarting"
      $RUNTIME start "$CONTAINER_NAME"
      log_ok "Container $CONTAINER_NAME started"
      return 0
    fi
  fi

  # Ensure data directory exists
  mkdir -p "$OLLAMA_CHAT_POSTGRES_DATA_DIR"

  log_info "Creating and starting container $CONTAINER_NAME ..."

  local runtime_args=()

  # Podman-specific: keep host UID mapping so volume permissions work
  if [ "$RUNTIME" = "podman" ]; then
    runtime_args+=(--userns=keep-id)
  fi

  $RUNTIME run -d \
    --name "$CONTAINER_NAME" \
    "${runtime_args[@]}" \
    -e POSTGRES_USER="$OLLAMA_CHAT_DB_USERNAME" \
    -e POSTGRES_PASSWORD="$OLLAMA_CHAT_DB_PASSWORD" \
    -e POSTGRES_DB="$OLLAMA_CHAT_DB_NAME" \
    -p "${OLLAMA_CHAT_DB_PORT}:5432" \
    -v "${OLLAMA_CHAT_POSTGRES_DATA_DIR}:/var/lib/postgresql/data:Z" \
    --restart unless-stopped \
    --health-cmd "pg_isready -U ${OLLAMA_CHAT_DB_USERNAME} -d ${OLLAMA_CHAT_DB_NAME}" \
    --health-interval 10s \
    --health-timeout 5s \
    --health-retries 5 \
    --health-start-period 30s \
    "$IMAGE_NAME" \
    postgres

  log_ok "Container $CONTAINER_NAME started on port $OLLAMA_CHAT_DB_PORT"
}

cmd_stop() {
  if ! container_exists; then
    log_info "Container $CONTAINER_NAME does not exist — nothing to stop"
    return 0
  fi

  if ! container_running; then
    log_info "Container $CONTAINER_NAME is already stopped"
    return 0
  fi

  log_info "Stopping container $CONTAINER_NAME ..."
  $RUNTIME stop "$CONTAINER_NAME"
  log_ok "Container $CONTAINER_NAME stopped"
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  if ! container_exists; then
    log_info "Container $CONTAINER_NAME does not exist"
    return 0
  fi

  local state
  state="$($RUNTIME container inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)"

  local health=""
  health="$($RUNTIME container inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"

  printf '\033[1;36m%-18s\033[0m %s\n' "Container:" "$CONTAINER_NAME"
  printf '\033[1;36m%-18s\033[0m %s\n' "Runtime:" "$RUNTIME"
  printf '\033[1;36m%-18s\033[0m %s\n' "Image:" "$IMAGE_NAME"
  printf '\033[1;36m%-18s\033[0m %s\n' "State:" "$state"
  if [ -n "$health" ]; then
    printf '\033[1;36m%-18s\033[0m %s\n' "Health:" "$health"
  fi
  printf '\033[1;36m%-18s\033[0m %s\n' "Port:" "$OLLAMA_CHAT_DB_PORT"
  printf '\033[1;36m%-18s\033[0m %s\n' "Data dir:" "$OLLAMA_CHAT_POSTGRES_DATA_DIR"
  printf '\033[1;36m%-18s\033[0m %s\n' "Database:" "$OLLAMA_CHAT_DB_NAME"
  printf '\033[1;36m%-18s\033[0m %s\n' "User:" "$OLLAMA_CHAT_DB_USERNAME"
}

cmd_logs() {
  if ! container_exists; then
    log_err "Container $CONTAINER_NAME does not exist"
    exit 1
  fi

  # Pass remaining args through (e.g. -f for follow)
  $RUNTIME logs "$@" "$CONTAINER_NAME"
}

cmd_shell() {
  if ! container_running; then
    log_err "Container $CONTAINER_NAME is not running"
    exit 1
  fi

  log_info "Opening psql shell in $CONTAINER_NAME ..."
  $RUNTIME exec -it "$CONTAINER_NAME" \
    psql -U "$OLLAMA_CHAT_DB_USERNAME" -d "$OLLAMA_CHAT_DB_NAME"
}

cmd_clean() {
  log_info "Cleaning up container and volume data ..."

  if container_running; then
    log_info "Stopping container $CONTAINER_NAME ..."
    $RUNTIME stop "$CONTAINER_NAME"
  fi

  if container_exists; then
    log_info "Removing container $CONTAINER_NAME ..."
    $RUNTIME rm -f "$CONTAINER_NAME"
  fi

  if [ -d "$OLLAMA_CHAT_POSTGRES_DATA_DIR" ]; then
    log_info "Removing data directory $OLLAMA_CHAT_POSTGRES_DATA_DIR ..."
    rm -rf "$OLLAMA_CHAT_POSTGRES_DATA_DIR"
  fi

  log_ok "Clean complete"
}

cmd_wait() {
  local max_seconds=30
  local elapsed=0

  if ! container_running; then
    log_err "Container $CONTAINER_NAME is not running"
    exit 1
  fi

  log_info "Waiting for PostgreSQL to be ready (up to ${max_seconds}s) ..."

  while [ $elapsed -lt $max_seconds ]; do
    if $RUNTIME exec "$CONTAINER_NAME" \
      pg_isready -U "$OLLAMA_CHAT_DB_USERNAME" -d "$OLLAMA_CHAT_DB_NAME" &>/dev/null; then
      log_ok "PostgreSQL is ready (took ${elapsed}s)"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  log_err "PostgreSQL did not become ready within ${max_seconds}s"
  exit 1
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

PostgreSQL container lifecycle management for Ollama Chat.

Commands:
  build     Build the Docker/Podman image
  start     Start the container (build & create if needed)
  stop      Stop the container
  restart   Stop then start the container
  status    Show container status
  logs      Show container logs (pass -f to follow)
  shell     Open a psql shell in the running container
  clean     Stop and remove container + volume data
  wait      Wait for PostgreSQL to be ready (up to 30s)

Environment variables (defaults shown):
  OLLAMA_CHAT_DB_USERNAME         ($OLLAMA_CHAT_DB_USERNAME)
  OLLAMA_CHAT_DB_PASSWORD         (*****)
  OLLAMA_CHAT_DB_NAME             ($OLLAMA_CHAT_DB_NAME)
  OLLAMA_CHAT_DB_PORT             ($OLLAMA_CHAT_DB_PORT)
  OLLAMA_CHAT_POSTGRES_DATA_DIR   ($OLLAMA_CHAT_POSTGRES_DATA_DIR)
  CONTAINER_NAME                  ($CONTAINER_NAME)
  IMAGE_NAME                      ($IMAGE_NAME)
EOF
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
detect_runtime

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  build)   cmd_build ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    cmd_logs "$@" ;;
  shell)   cmd_shell ;;
  clean)   cmd_clean ;;
  wait)    cmd_wait ;;
  help|-h|--help) usage ;;
  *)
    log_err "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac

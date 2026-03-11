#!/bin/sh
# MCP Test Server - Clean stdio startup script
# Ensures only JSON-RPC messages appear on stdout

# Change to script directory
cd "$(dirname "$0")" || exit 1

# Compile first, sending all output to stderr
mix compile >&2

# Now run - app outputs JSON-RPC to stdout, everything else goes to stderr
exec mix run --no-halt

#!/usr/bin/env bash

# MCP Test Server Start Script
# This script starts the Elixir-based MCP test server

set -e

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  MCP Test Server${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if Mix is available
if ! command -v mix &> /dev/null; then
    echo -e "${RED}Error: Elixir/Mix not found!${NC}"
    echo "Please install Elixir: https://elixir-lang.org/install.html"
    exit 1
fi

# Set workspace path (can be overridden with environment variable)
if [ -z "$MCP_WORKSPACE" ]; then
    export MCP_WORKSPACE="$SCRIPT_DIR/../tmp/mcp_workspace"
fi

# Create workspace directory if it doesn't exist
mkdir -p "$MCP_WORKSPACE"

echo -e "${GREEN}✓${NC} Workspace: $MCP_WORKSPACE"

# Check if dependencies are installed
if [ ! -d "deps" ]; then
    echo -e "${YELLOW}Installing dependencies...${NC}"
    mix deps.get
    echo -e "${GREEN}✓${NC} Dependencies installed"
else
    echo -e "${GREEN}✓${NC} Dependencies already installed"
fi

# Compile the project
echo -e "${YELLOW}Compiling project...${NC}"
mix compile
echo -e "${GREEN}✓${NC} Project compiled"

echo ""
echo -e "${GREEN}Starting MCP Test Server...${NC}"
echo ""
echo "Available tools:"
echo "  📁 Filesystem: read_file, write_file, list_directory, file_info"
echo "  💾 Memory: memory_set, memory_get, memory_delete, memory_list"
echo "  🔧 Utility: echo, get_time, random_number, hash_text"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop the server${NC}"
echo ""
echo -e "${BLUE}========================================${NC}"
echo ""

# Start the server
exec mix run --no-halt

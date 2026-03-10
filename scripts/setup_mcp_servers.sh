#!/usr/bin/env bash

set -e

echo "================================================"
echo "MCP Test Servers Setup"
echo "================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if Node.js is installed
echo -n "Checking for Node.js... "
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    echo -e "${GREEN}✓${NC} Found Node.js ${NODE_VERSION}"
else
    echo -e "${RED}✗${NC} Node.js not found"
    echo ""
    echo "Please install Node.js 18+ from https://nodejs.org/"
    exit 1
fi

# Check if npm/npx is installed
echo -n "Checking for npm... "
if command -v npm &> /dev/null; then
    NPM_VERSION=$(npm --version)
    echo -e "${GREEN}✓${NC} Found npm ${NPM_VERSION}"
else
    echo -e "${RED}✗${NC} npm not found"
    exit 1
fi

echo ""
echo "================================================"
echo "Installing MCP Test Servers"
echo "================================================"
echo ""

# Create workspace directory
WORKSPACE_DIR="./tmp/mcp_workspace"
echo "Creating workspace directory: ${WORKSPACE_DIR}"
mkdir -p "${WORKSPACE_DIR}"

# Create test files
echo "Creating test files..."
echo "Hello from MCP test workspace!" > "${WORKSPACE_DIR}/test.txt"
echo "# Test Markdown File" > "${WORKSPACE_DIR}/test.md"
echo '{"test": "data"}' > "${WORKSPACE_DIR}/test.json"

echo -e "${GREEN}✓${NC} Test files created"
echo ""

# Test MCP Filesystem Server
echo "Testing @modelcontextprotocol/server-filesystem..."
echo -n "Checking if installed... "

if npx -y @modelcontextprotocol/server-filesystem --help &> /dev/null; then
    echo -e "${GREEN}✓${NC} Available via npx"
else
    echo -e "${YELLOW}!${NC} Will download on first use"
fi

echo ""

# Test MCP Time Server (optional)
echo "Testing @modelcontextprotocol/server-time..."
echo -n "Checking if installed... "

if npx -y @modelcontextprotocol/server-time --help &> /dev/null; then
    echo -e "${GREEN}✓${NC} Available via npx"
else
    echo -e "${YELLOW}!${NC} Will download on first use"
fi

echo ""
echo "================================================"
echo "MCP Servers Ready"
echo "================================================"
echo ""
echo "Available MCP servers:"
echo "  • @modelcontextprotocol/server-filesystem"
echo "  • @modelcontextprotocol/server-time"
echo ""
echo "Test workspace: ${WORKSPACE_DIR}"
echo ""
echo "To start the Phoenix server with MCP enabled:"
echo "  ${GREEN}mix phx.server${NC}"
echo ""
echo "The filesystem server will be configured to access:"
echo "  ${WORKSPACE_DIR}"
echo ""
echo -e "${GREEN}Setup complete!${NC}"

#!/bin/bash

# scripts/dev-start-iex.sh
# Development startup script for CorroPort in iex
# Make sure the appropriate Corrosion agent is running with
# something like 
# ./corrosion/corrosion-mac agent --config ./corrosion/config-node1.toml
#
# Usage:
#   ./scripts/dev-start-iex.sh [NODE_ID]
#   NODE_ID=2 ./scripts/dev-start-iex.sh
#   ./scripts/dev-start-iex.sh 3

set -e

# Get node ID from argument or environment, default to 1
NODE_ID=${1:-${NODE_ID:-1}}

echo "🚀 Starting CorroPort development node ${NODE_ID}..."

# Validate node ID
if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]] || [ "$NODE_ID" -lt 1 ] || [ "$NODE_ID" -gt 10 ]; then
    echo "❌ Error: NODE_ID must be a number between 1 and 10"
    exit 1
fi

# Calculate ports based on node ID
PHOENIX_PORT=$((4000 + NODE_ID))
CORROSION_API_PORT=$((8080 + NODE_ID))
CORROSION_GOSSIP_PORT=$((8786 + NODE_ID))

# Generate bootstrap list (exclude current node)
BOOTSTRAP_PORTS=""
for i in {1..5}; do
    if [ $i -ne $NODE_ID ]; then
        PORT=$((8786 + i))
        if [ -n "$BOOTSTRAP_PORTS" ]; then
            BOOTSTRAP_PORTS="$BOOTSTRAP_PORTS, "
        fi
        BOOTSTRAP_PORTS="$BOOTSTRAP_PORTS\"127.0.0.1:$PORT\""
    fi
done
BOOTSTRAP_LIST="[$BOOTSTRAP_PORTS]"

# Paths
CONFIG_PATH="corrosion/config-node${NODE_ID}.toml"
DB_PATH="corrosion/dev-node${NODE_ID}.db"
ADMIN_SOCKET="/tmp/corrosion/node${NODE_ID}_admin.sock"

echo "📋 Node Configuration:"
echo "   Node ID: $NODE_ID"
echo "   Phoenix: http://localhost:$PHOENIX_PORT"
echo "   Corrosion API: http://127.0.0.1:$CORROSION_API_PORT"
echo "   Corrosion Gossip: 127.0.0.1:$CORROSION_GOSSIP_PORT"
echo "   Database: $DB_PATH"
echo "   Config: $CONFIG_PATH"
echo ""


# Set environment variables for the Elixir app
export NODE_ID="$NODE_ID"
export PHX_SERVER=true
export MIX_ENV=dev

echo ""

pwd

iex -S mix phx.server
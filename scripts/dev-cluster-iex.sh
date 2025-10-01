#!/bin/bash

# scripts/dev-cluster-iex.sh
# Start multiple CorroPort nodes for cluster testing with iex
# Assumes corrosion agents are already running
#
# Usage:
# 
#   ./scripts/dev-cluster-iex.sh 3           # Start a 3-node cluster (node 1 interactive, nodes 2-3 background)
#   ./scripts/dev-cluster-iex.sh --nodes 5   # Start 5 nodes
#   ./scripts/dev-cluster-iex.sh --help      # Show help

#   ./scripts/dev-cluster-iex.sh --verbose --nodes 4  # Start with verbose logging for background nodes

# You can check background node logs with:
#   tail -f logs/node2.log
#   tail -f logs/node3.log

set -e

# Default values
NUM_NODES=3
VERBOSE=false
EXPERIMENT_ID=""
TRANSACTION_SIZE_BYTES=1024
TRANSACTION_FREQUENCY_MS=5000

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --nodes|-n)
            NUM_NODES="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --experiment-id|-e)
            EXPERIMENT_ID="$2"
            shift 2
            ;;
        --transaction-size)
            TRANSACTION_SIZE_BYTES="$2"
            shift 2
            ;;
        --transaction-frequency)
            TRANSACTION_FREQUENCY_MS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [NUM_NODES]"
            echo ""
            echo "Start multiple CorroPort development nodes for cluster testing with iex"
            echo ""
            echo "PREREQUISITES:"
            echo "  Corrosion agents must already be running. Start them with:"
            echo "  ./corrosion/corrosion-mac agent --config ./corrosion/config-node1.toml"
            echo "  ./corrosion/corrosion-mac agent --config ./corrosion/config-node2.toml"
            echo "  etc."
            echo ""
            echo "OPTIONS:"
            echo "  -n, --nodes NUM              Number of nodes to start (default: 3)"
            echo "  -v, --verbose                Enable verbose output"
            echo "  -e, --experiment-id ID       Set experiment ID for analytics"
            echo "      --transaction-size BYTES Set transaction size in bytes (default: 1024)"
            echo "      --transaction-frequency MS Set transaction frequency in ms (default: 5000)"
            echo "  -h, --help                   Show this help message"
            echo ""
            echo "EXAMPLES:"
            echo "  $0 3                                    Start 3 nodes"
            echo "  $0 --nodes 5                            Start 5 nodes"
            echo "  $0 --experiment-id high_load_test       Start with custom experiment ID"
            echo "  $0 --transaction-size 2048 --nodes 3    Start 3 nodes with 2KB transactions"
            echo ""
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                NUM_NODES="$1"
            else
                echo "❌ Error: Unknown argument '$1'"
                echo "Use --help for usage information"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate number of nodes
if ! [[ "$NUM_NODES" =~ ^[0-9]+$ ]] || [ "$NUM_NODES" -lt 1 ] || [ "$NUM_NODES" -gt 10 ]; then
    echo "❌ Error: Number of nodes must be between 1 and 10"
    exit 1
fi

# Generate experiment ID if not provided
if [ -z "$EXPERIMENT_ID" ]; then
    EXPERIMENT_ID="cluster_$(date +%Y%m%d_%H%M%S)"
fi

echo "🚀 Starting $NUM_NODES-node CorroPort development cluster with iex..."
echo ""
echo "⚠️  Prerequisites: Ensure corrosion agents are already running:"
for i in $(seq 1 $NUM_NODES); do
    echo "   ./corrosion/corrosion-mac agent --config ./corrosion/config-node$i.toml"
done
echo ""

echo "🧪 Experiment Configuration:"
echo "   Experiment ID: $EXPERIMENT_ID"
echo "   Transaction Size: ${TRANSACTION_SIZE_BYTES} bytes"
echo "   Transaction Frequency: ${TRANSACTION_FREQUENCY_MS} ms"
echo ""

# Show cluster information
echo "📋 Cluster Information:"
echo "======================="
for i in $(seq 1 $NUM_NODES); do
    PHOENIX_PORT=$((4000 + i))
    CORRO_API_PORT=$((8080 + i))
    GOSSIP_PORT=$((8786 + i))
    echo "Node $i:"
    echo "  Phoenix:      http://localhost:$PHOENIX_PORT"
    echo "  Corrosion API: http://127.0.0.1:$CORRO_API_PORT"
    echo "  Gossip:       127.0.0.1:$GOSSIP_PORT"
    echo ""
done

# Cleanup function
cleanup() {
    echo ""
    echo "🛑 Stopping cluster..."
    
    # Kill all background processes
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            if [ "$VERBOSE" = true ]; then
                echo "   Stopping process $pid"
            fi
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    echo "✅ Cluster stopped (corrosion agents still running)"
    exit 0
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Array to store background process PIDs
pids=()

# Create logs directory if it doesn't exist
mkdir -p logs

# Compile first to avoid build directory lock contention
echo "🔨 Compiling application..."
mix compile
echo "✅ Compilation complete!"
echo ""

# Start background nodes first (nodes 2+)
if [ "$NUM_NODES" -gt 1 ]; then
    echo "🔧 Starting background nodes..."
    for i in $(seq 2 $NUM_NODES); do
        echo "   Starting node $i in background..."
        
        # Start background nodes with mix phx.server
        if [ "$VERBOSE" = true ]; then
            EXPERIMENT_ID=$EXPERIMENT_ID TRANSACTION_SIZE_BYTES=$TRANSACTION_SIZE_BYTES TRANSACTION_FREQUENCY_MS=$TRANSACTION_FREQUENCY_MS NODE_ID=$i PHX_SERVER=true mix phx.server > "logs/node$i.log" 2>&1 &
        else
            EXPERIMENT_ID=$EXPERIMENT_ID TRANSACTION_SIZE_BYTES=$TRANSACTION_SIZE_BYTES TRANSACTION_FREQUENCY_MS=$TRANSACTION_FREQUENCY_MS NODE_ID=$i PHX_SERVER=true mix phx.server > /dev/null 2>&1 &
        fi
        
        pid=$!
        pids+=($pid)
        
        # Give each node time to start
        sleep 2
    done
    
    echo "✅ Background nodes started!"
    echo ""
fi

# Start node 1 with iex in foreground
echo "🔧 Starting node 1 with iex (interactive)..."
echo "   You can interact with node 1 and see its logs directly"
echo "   Other nodes are running in the background"
echo ""

# Set environment for node 1
export EXPERIMENT_ID=$EXPERIMENT_ID
export TRANSACTION_SIZE_BYTES=$TRANSACTION_SIZE_BYTES
export TRANSACTION_FREQUENCY_MS=$TRANSACTION_FREQUENCY_MS
export NODE_ID=1
export PHX_SERVER=true
export MIX_ENV=dev

# Calculate ports for node 1
PHOENIX_PORT=4001
CORROSION_API_PORT=8081
CORROSION_GOSSIP_PORT=8787

echo "📋 Node 1 Configuration:"
echo "   Node ID: 1"
echo "   Phoenix:      http://localhost:$PHOENIX_PORT"
echo "   Corrosion API: http://127.0.0.1:$CORROSION_API_PORT"
echo "   Corrosion Gossip: 127.0.0.1:$CORROSION_GOSSIP_PORT"
echo ""

# Start node 1 in foreground with iex
iex -S mix phx.server
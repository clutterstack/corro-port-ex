#!/bin/bash

# scripts/dev-cluster.sh
# Start multiple CorroPort nodes for cluster testing
#
# Usage:
#   ./scripts/dev-cluster.sh 3           # Start 3 nodes
#   ./scripts/dev-cluster.sh --nodes 5   # Start 5 nodes
#   ./scripts/dev-cluster.sh --help      # Show help

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
            echo "Start multiple CorroPort development nodes for cluster testing"
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

echo "🚀 Starting $NUM_NODES-node CorroPort development cluster..."
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
    echo "  Phoenix:   http://localhost:$PHOENIX_PORT"
    echo "  Corrosion API:       http://127.0.0.1:$CORRO_API_PORT"
    echo "  Gossip:    127.0.0.1:$GOSSIP_PORT"
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
    
    # Clean up any remaining corrosion processes
    pkill -f "corrosion.*agent" 2>/dev/null || true
    
    echo "✅ Cluster stopped"
    exit 0
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Array to store background process PIDs
pids=()

# Start nodes in background
echo "🔧 Starting nodes..."
for i in $(seq 1 $NUM_NODES); do
    echo "   Starting node $i..."
    
    # Start in background with output redirected to log files
    if [ "$VERBOSE" = true ]; then
        EXPERIMENT_ID=$EXPERIMENT_ID TRANSACTION_SIZE_BYTES=$TRANSACTION_SIZE_BYTES TRANSACTION_FREQUENCY_MS=$TRANSACTION_FREQUENCY_MS NODE_ID=$i ./scripts/dev-start.sh > "logs/node$i.log" 2>&1 &
    else
        EXPERIMENT_ID=$EXPERIMENT_ID TRANSACTION_SIZE_BYTES=$TRANSACTION_SIZE_BYTES TRANSACTION_FREQUENCY_MS=$TRANSACTION_FREQUENCY_MS NODE_ID=$i ./scripts/dev-start.sh > /dev/null 2>&1 &
    fi
    
    pid=$!
    pids+=($pid)
    
    # Give each node time to start
    sleep 2
done

echo ""
echo "✅ All nodes started!"
echo ""
echo "🌐 Access your cluster:"
for i in $(seq 1 $NUM_NODES); do
    PHOENIX_PORT=$((4000 + i))
    echo "   Node $i: http://localhost:$PHOENIX_PORT/cluster"
done

echo ""
echo "📝 Logs are available in:"
echo "   logs/node1.log, logs/node2.log, etc."
echo ""
echo "⏹️  Press Ctrl+C to stop the entire cluster"

# Create logs directory if it doesn't exist
mkdir -p logs

# Wait for all background processes
wait
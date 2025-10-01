#!/bin/bash

# scripts/corrosion-start.sh
# Start corrosion agents for local cluster development
#
# Usage:
#   ./scripts/corrosion-start.sh           # Start 3 agents (default)
#   ./scripts/corrosion-start.sh 5         # Start 5 agents
#   ./scripts/corrosion-start.sh --help    # Show help

set -e

# Default values
NUM_AGENTS=3
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --agents|-n)
            NUM_AGENTS="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [NUM_AGENTS]"
            echo ""
            echo "Start corrosion agents for local cluster development"
            echo ""
            echo "OPTIONS:"
            echo "  -n, --agents NUM    Number of agents to start (default: 3)"
            echo "  -v, --verbose       Enable verbose output"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "EXAMPLES:"
            echo "  $0                  Start 3 agents"
            echo "  $0 5                Start 5 agents"
            echo "  $0 --agents 4       Start 4 agents"
            echo ""
            echo "NOTES:"
            echo "  - Agents run in background with logs in logs/corrosion-nodeN.log"
            echo "  - Use ./scripts/corrosion-stop.sh to stop all agents"
            echo "  - Config files must exist: corrosion/config-nodeN.toml"
            echo ""
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                NUM_AGENTS="$1"
            else
                echo "Error: Unknown argument '$1'"
                echo "Use --help for usage information"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate number of agents
if ! [[ "$NUM_AGENTS" =~ ^[0-9]+$ ]] || [ "$NUM_AGENTS" -lt 1 ] || [ "$NUM_AGENTS" -gt 10 ]; then
    echo "Error: Number of agents must be between 1 and 10"
    exit 1
fi

# Check if binary exists
BINARY="./corrosion/corrosion-mac"
if [ ! -f "$BINARY" ]; then
    echo "Error: Corrosion binary not found at $BINARY"
    echo "Please ensure the binary exists and is executable"
    exit 1
fi

if [ ! -x "$BINARY" ]; then
    echo "Error: Corrosion binary is not executable: $BINARY"
    echo "Run: chmod +x $BINARY"
    exit 1
fi

echo "Starting $NUM_AGENTS corrosion agent(s)..."
echo ""

# Create logs directory if it doesn't exist
mkdir -p logs

# Check for already running agents
RUNNING_COUNT=0
for i in $(seq 1 $NUM_AGENTS); do
    CONFIG_FILE="corrosion/config-node$i.toml"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file not found: $CONFIG_FILE"
        exit 1
    fi

    # Check if already running
    if pgrep -f "corrosion.*config-node$i.toml" > /dev/null; then
        echo "Agent $i: Already running (skipping)"
        RUNNING_COUNT=$((RUNNING_COUNT + 1))
    fi
done

# Start agents that aren't running
STARTED_COUNT=0
for i in $(seq 1 $NUM_AGENTS); do
    CONFIG_FILE="corrosion/config-node$i.toml"
    LOG_FILE="logs/corrosion-node$i.log"

    # Skip if already running
    if pgrep -f "corrosion.*config-node$i.toml" > /dev/null; then
        continue
    fi

    echo "Agent $i: Starting..."

    if [ "$VERBOSE" = true ]; then
        $BINARY agent --config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
        echo "         Log: $LOG_FILE"
    else
        $BINARY agent --config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    fi

    PID=$!

    # Give it a moment to start
    sleep 1

    # Verify it's still running
    if kill -0 $PID 2>/dev/null; then
        echo "         PID: $PID"
        STARTED_COUNT=$((STARTED_COUNT + 1))
    else
        echo "         ERROR: Failed to start (check $LOG_FILE)"
        exit 1
    fi

    echo ""
done

echo "Summary:"
echo "  Already running: $RUNNING_COUNT"
echo "  Newly started:   $STARTED_COUNT"
echo "  Total running:   $((RUNNING_COUNT + STARTED_COUNT))"
echo ""

if [ "$VERBOSE" = true ]; then
    echo "View logs with:"
    for i in $(seq 1 $NUM_AGENTS); do
        echo "  tail -f logs/corrosion-node$i.log"
    done
    echo ""
fi

echo "Corrosion agent ports:"
for i in $(seq 1 $NUM_AGENTS); do
    API_PORT=$((8080 + i))
    GOSSIP_PORT=$((8786 + i))
    echo "  Node $i: API=http://127.0.0.1:$API_PORT, Gossip=127.0.0.1:$GOSSIP_PORT"
done
echo ""

echo "Stop agents with: ./scripts/corrosion-stop.sh"
echo "Start Phoenix cluster with: ./scripts/dev-cluster-iex.sh"

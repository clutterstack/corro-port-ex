#!/bin/bash

# scripts/corrosion-stop.sh
# Stop all running corrosion agents for local cluster development
#
# Usage:
#   ./scripts/corrosion-stop.sh           # Stop all agents
#   ./scripts/corrosion-stop.sh --help    # Show help

set -e

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo "Usage: $0"
            echo ""
            echo "Stop all running corrosion agents for local cluster development"
            echo ""
            echo "This script will:"
            echo "  1. Find all running corrosion agent processes"
            echo "  2. Send SIGTERM to gracefully shut them down"
            echo "  3. Wait up to 10 seconds for graceful shutdown"
            echo "  4. Force kill any remaining processes"
            echo ""
            echo "OPTIONS:"
            echo "  -h, --help    Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "Stopping corrosion agents..."
echo ""

# Find all corrosion agent processes
PIDS=$(pgrep -f "corrosion.*agent.*config-node" || true)

if [ -z "$PIDS" ]; then
    echo "No corrosion agents found running"
    exit 0
fi

# Count processes
COUNT=$(echo "$PIDS" | wc -l | tr -d ' ')
echo "Found $COUNT corrosion agent process(es)"
echo ""

# Show which nodes are running
for PID in $PIDS; do
    CMD=$(ps -p $PID -o command= 2>/dev/null || echo "unknown")

    # Extract node number from command
    if [[ $CMD =~ config-node([0-9]+)\.toml ]]; then
        NODE_NUM="${BASH_REMATCH[1]}"
        echo "  Node $NODE_NUM (PID: $PID)"
    else
        echo "  Unknown node (PID: $PID)"
    fi
done
echo ""

# Send SIGTERM for graceful shutdown
echo "Sending SIGTERM for graceful shutdown..."
for PID in $PIDS; do
    kill -TERM $PID 2>/dev/null || true
done

# Wait for processes to exit (max 10 seconds)
echo "Waiting for processes to exit (max 10 seconds)..."
WAITED=0
while [ $WAITED -lt 10 ]; do
    REMAINING=$(pgrep -f "corrosion.*agent.*config-node" || true)

    if [ -z "$REMAINING" ]; then
        echo "All processes exited gracefully"
        echo ""
        echo "Corrosion agents stopped successfully"
        exit 0
    fi

    sleep 1
    WAITED=$((WAITED + 1))
    echo -n "."
done
echo ""

# Force kill any remaining processes
REMAINING=$(pgrep -f "corrosion.*agent.*config-node" || true)
if [ -n "$REMAINING" ]; then
    echo "Some processes did not exit gracefully, force killing..."

    for PID in $REMAINING; do
        kill -9 $PID 2>/dev/null || true
    done

    sleep 1

    # Check if any are still running
    STILL_RUNNING=$(pgrep -f "corrosion.*agent.*config-node" || true)
    if [ -n "$STILL_RUNNING" ]; then
        echo "Warning: Some processes could not be killed:"
        for PID in $STILL_RUNNING; do
            echo "  PID: $PID"
        done
        exit 1
    fi
fi

echo ""
echo "Corrosion agents stopped successfully"

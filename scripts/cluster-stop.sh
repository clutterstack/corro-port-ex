#!/bin/bash

# scripts/cluster-stop.sh
# Stop all cluster nodes (overmind daemons + Phoenix processes)
#
# Usage:
#   ./scripts/cluster-stop.sh           # Stop all nodes
#   ./scripts/cluster-stop.sh --help    # Show help

set -e

# Determine overmind binary based on OS
case "$(uname -s)" in
    Darwin)
        OVERMIND_BIN="./overmind-v2.5.1-macos-arm64"
        ;;
    Linux)
        OVERMIND_BIN="./overmind-v2.5.1-linux-amd64"
        ;;
    *)
        OVERMIND_BIN=""
        ;;
esac

# Parse arguments
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: $0"
    echo ""
    echo "Stop all cluster nodes"
    echo ""
    echo "This script stops all overmind daemons and Phoenix processes."
    echo "It finds .overmind-node*.sock files and .phoenix-node*.pid files."
    echo ""
    exit 0
fi

echo "🛑 Stopping all cluster nodes..."
echo ""

STOPPED_COUNT=0

# Stop all overmind daemons
if [ -n "$OVERMIND_BIN" ] && [ -f "$OVERMIND_BIN" ]; then
    for socket_file in .overmind-node*.sock; do
        if [ -e "$socket_file" ]; then
            # Extract node number
            if [[ "$socket_file" =~ overmind-node([0-9]+) ]]; then
                NODE_NUM="${BASH_REMATCH[1]}"
            else
                continue
            fi

            echo "  Stopping overmind for node $NODE_NUM..."
            OVERMIND_SOCKET="$socket_file" "$OVERMIND_BIN" quit 2>/dev/null || true
            STOPPED_COUNT=$((STOPPED_COUNT + 1))
            rm -f "$socket_file"
        fi
    done
fi

# Stop Phoenix processes
for pid_file in .phoenix-node*.pid; do
    if [ -f "$pid_file" ]; then
        PID=$(cat "$pid_file")

        # Extract node number
        if [[ "$pid_file" =~ phoenix-node([0-9]+) ]]; then
            NODE_NUM="${BASH_REMATCH[1]}"
        else
            continue
        fi

        if ps -p "$PID" > /dev/null 2>&1; then
            echo "  Stopping Phoenix for node $NODE_NUM (PID: $PID)..."
            kill "$PID" 2>/dev/null || true
            STOPPED_COUNT=$((STOPPED_COUNT + 1))
        fi

        rm -f "$pid_file"
    fi
done

echo ""
if [ $STOPPED_COUNT -gt 0 ]; then
    echo "✅ Stopped $STOPPED_COUNT processes"
else
    echo "No running processes found"
fi

# Clean up subscription directories to prevent restore issues on next start
if [ -d "corrosion/subscriptions" ]; then
    echo ""
    echo "🧹 Cleaning up subscription directories..."
    rm -rf corrosion/subscriptions/*
    echo "✅ Subscription directories cleaned"
fi

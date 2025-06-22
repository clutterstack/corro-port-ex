#!/bin/bash

# scripts/analytics-demo.sh
# Complete analytics demonstration script for CorroPort
# Automates the full flow: cluster setup → aggregation → message sending → data collection

set -e

# Configuration
DEFAULT_NODES=2
DEFAULT_EXPERIMENT_ID="demo_$(date +%Y%m%d_%H%M%S)"
DEFAULT_MESSAGE_COUNT=3
DEFAULT_WAIT_TIME=10

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
NODES=${1:-$DEFAULT_NODES}
EXPERIMENT_ID=${2:-$DEFAULT_EXPERIMENT_ID}
MESSAGE_COUNT=${3:-$DEFAULT_MESSAGE_COUNT}
WAIT_TIME=${4:-$DEFAULT_WAIT_TIME}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
}

print_step() {
    echo -e "${GREEN}→ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

cleanup() {
    print_header "🛑 Cleanup"
    print_step "Stopping any running Phoenix processes..."
    pkill -f "phx.server" 2>/dev/null || true
    print_step "Cleanup complete"
    exit 0
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Function to wait for service
wait_for_service() {
    local url=$1
    local name=$2
    local max_attempts=30
    local attempt=1
    
    print_step "Waiting for $name to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s -f "$url" > /dev/null 2>&1; then
            print_success "$name is ready!"
            return 0
        fi
        echo -n "."
        sleep 1
        ((attempt++))
    done
    
    print_error "$name failed to start within $max_attempts seconds"
    return 1
}

# Function to check corrosion agents
check_corrosion_agents() {
    print_step "Checking Corrosion agents..."
    local agents_running=0
    
    for i in $(seq 1 $NODES); do
        local port=$((8080 + i))
        
        # Use CorrosionClient.test_corro_conn/1 to check agent connectivity
        cat > /tmp/test_corro_conn.exs << EOF
result = CorroPort.CorrosionClient.test_corro_conn($port)
case result do
  :ok -> 
    IO.puts("✅ Corrosion agent $i (port $port) is running")
    System.halt(0)
  error -> 
    IO.puts("❌ Corrosion agent $i (port $port) failed: #{inspect(error)}")
    System.halt(1)
end
EOF
        
        if NODE_ID=1 mix run /tmp/test_corro_conn.exs > /dev/null 2>&1; then
            print_success "Corrosion agent $i (port $port) is running"
            ((agents_running++))
        else
            print_warning "Corrosion agent $i (port $port) is not running"
        fi
    done
    
    if [ $agents_running -eq 0 ]; then
        print_error "No Corrosion agents are running. Please start them first:"
        for i in $(seq 1 $NODES); do
            echo "  ./corrosion/corrosion-mac agent --config ./corrosion/config-node$i.toml"
        done
        exit 1
    fi
    
    print_success "$agents_running/$NODES Corrosion agents are running"
}

# Function to start Phoenix cluster
start_phoenix_cluster() {
    print_step "Starting $NODES-node Phoenix cluster..."
    
    # Start background nodes
    for i in $(seq 2 $NODES); do
        print_step "Starting Phoenix node $i in background..."
        NODE_ID=$i EXPERIMENT_ID=$EXPERIMENT_ID PHX_SERVER=true \
            mix phx.server > "logs/demo_node$i.log" 2>&1 &
        local pid=$!
        echo $pid > "logs/demo_node$i.pid"
        print_success "Node $i started (PID: $pid)"
        sleep 2
    done
    
    # Start node 1
    print_step "Starting Phoenix node 1..."
    NODE_ID=1 EXPERIMENT_ID=$EXPERIMENT_ID PHX_SERVER=true \
        mix phx.server > "logs/demo_node1.log" 2>&1 &
    local pid=$!
    echo $pid > "logs/demo_node1.pid"
    print_success "Node 1 started (PID: $pid)"
    
    # Wait for all nodes to be ready
    for i in $(seq 1 $NODES); do
        local port=$((4000 + i))
        wait_for_service "http://localhost:$port/api/analytics/health" "Phoenix node $i"
    done
}

# Function to demonstrate analytics aggregation
demonstrate_aggregation() {
    print_step "Starting analytics aggregation for experiment: $EXPERIMENT_ID"
    
    # Use the new HTTP API endpoint
    response=$(curl -s -X POST "http://localhost:4001/api/analytics/aggregation/start" \
        -H "Content-Type: application/json" \
        -d "{\"experiment_id\": \"$EXPERIMENT_ID\"}")
    
    if echo "$response" | grep -q '"status":"success"'; then
        print_success "Analytics aggregation started via HTTP API"
        echo "Response: $response" | jq . 2>/dev/null || echo "Response: $response"
    else
        print_warning "HTTP API failed, falling back to mix run..."
        
        # Fallback to mix run
        cat > /tmp/start_aggregation.exs << EOF
IO.puts("Starting aggregation for experiment: $EXPERIMENT_ID")
result = CorroPort.AnalyticsAggregator.start_experiment_aggregation("$EXPERIMENT_ID")
IO.puts("Aggregation result: #{inspect(result)}")

# Get initial node count
nodes = CorroPort.AnalyticsAggregator.get_active_nodes()
IO.puts("Active nodes discovered: #{length(nodes)}")
Enum.each(nodes, fn node -> IO.puts("  - #{node.node_id} (#{node.region})") end)
EOF
        
        NODE_ID=1 mix run /tmp/start_aggregation.exs
        print_success "Analytics aggregation started via fallback"
    fi
    
    # Show aggregation status
    print_step "Checking aggregation status..."
    curl -s "http://localhost:4001/api/analytics/aggregation/status" | jq . 2>/dev/null || \
        curl -s "http://localhost:4001/api/analytics/aggregation/status"
    echo
}

# Function to send test messages
send_test_messages() {
    print_step "Sending $MESSAGE_COUNT test messages..."
    
    for i in $(seq 1 $MESSAGE_COUNT); do
        message_content="Analytics demo message #$i - timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        
        # Try HTTP API first
        response=$(curl -s -X POST "http://localhost:4001/api/messages/send" \
            -H "Content-Type: application/json" \
            -d "{\"content\": \"$message_content\"}")
        
        if echo "$response" | grep -q '"status":"success"'; then
            print_success "Message #$i sent via HTTP API"
            echo "$response" | jq -r '.message.pk' 2>/dev/null | sed 's/^/  Message ID: /' || echo "  Response: $response"
        else
            print_warning "HTTP API failed for message #$i, using fallback..."
            
            # Fallback to mix run
            cat > /tmp/send_message.exs << EOF
IO.puts("Sending test message #$i")
result = CorroPort.MessagePropagation.send_message("$message_content")
case result do
  {:ok, message_data} -> 
    IO.puts("✅ Message sent successfully: #{message_data.pk}")
  {:error, reason} -> 
    IO.puts("❌ Message failed: #{inspect(reason)}")
end
EOF
            
            NODE_ID=1 mix run /tmp/send_message.exs
        fi
        
        sleep 2
    done
    
    print_success "All test messages sent"
}

# Function to collect and display results
display_results() {
    print_step "Waiting $WAIT_TIME seconds for data aggregation..."
    sleep $WAIT_TIME
    
    print_header "📊 Analytics Results"
    
    # Get cluster summary
    print_step "Cluster Summary:"
    curl -s "http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/summary" | jq . 2>/dev/null || \
        curl -s "http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/summary"
    echo
    
    # Get timing stats
    print_step "Message Timing Stats:"
    curl -s "http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/timing" | jq . 2>/dev/null || \
        curl -s "http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/timing"
    echo
    
    # Check each node's health
    print_step "Node Health Status:"
    for i in $(seq 1 $NODES); do
        local port=$((4000 + i))
        echo "Node $i:"
        curl -s "http://localhost:$port/api/analytics/health" | jq . 2>/dev/null || \
            curl -s "http://localhost:$port/api/analytics/health"
        echo
    done
}

# Function to show access information
show_access_info() {
    print_header "🌐 Access Information"
    echo "Analytics Dashboard URLs:"
    for i in $(seq 1 $NODES); do
        local port=$((4000 + i))
        echo "  Node $i: http://localhost:$port/analytics?experiment_id=$EXPERIMENT_ID"
    done
    echo
    echo "Cluster Monitoring URLs:"
    for i in $(seq 1 $NODES); do
        local port=$((4000 + i))
        echo "  Node $i: http://localhost:$port/cluster"
    done
    echo
    echo "API Endpoints:"
    echo "  Health: http://localhost:4001/api/analytics/health"
    echo "  Summary: http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/summary"
    echo "  Timing: http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/timing"
    echo "  Metrics: http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/metrics"
    echo
}

# Main execution
main() {
    print_header "🚀 CorroPort Analytics Demonstration"
    echo "Configuration:"
    echo "  Nodes: $NODES"
    echo "  Experiment ID: $EXPERIMENT_ID"
    echo "  Test Messages: $MESSAGE_COUNT"
    echo "  Wait Time: ${WAIT_TIME}s"
    echo
    
    # Create logs directory
    mkdir -p logs
    
    # Run demonstration steps
    check_corrosion_agents
    start_phoenix_cluster
    demonstrate_aggregation
    send_test_messages
    display_results
    show_access_info
    
    print_header "✅ Demonstration Complete"
    print_success "Analytics aggregation is running and collecting data"
    print_warning "Cluster will continue running. Press Ctrl+C to stop."
    
    # Keep script running to maintain cluster
    while true; do
        sleep 30
        print_step "Cluster still running... ($(date))"
        # Optional: Show live stats
        echo "Active aggregation experiment: $EXPERIMENT_ID"
        curl -s "http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/summary" | \
            jq -r '"Messages: \(.message_count), Acks: \(.ack_count), Metrics: \(.system_metrics_count)"' 2>/dev/null || true
        echo
    done
}

# Help function
show_help() {
    echo "Usage: $0 [NODES] [EXPERIMENT_ID] [MESSAGE_COUNT] [WAIT_TIME]"
    echo ""
    echo "Arguments:"
    echo "  NODES         Number of nodes to start (default: $DEFAULT_NODES)"
    echo "  EXPERIMENT_ID Experiment identifier (default: auto-generated)"
    echo "  MESSAGE_COUNT Number of test messages (default: $DEFAULT_MESSAGE_COUNT)"
    echo "  WAIT_TIME     Seconds to wait for aggregation (default: $DEFAULT_WAIT_TIME)"
    echo ""
    echo "Examples:"
    echo "  $0                           # Use all defaults"
    echo "  $0 3                         # 3 nodes"
    echo "  $0 2 my_experiment          # 2 nodes, custom experiment"
    echo "  $0 3 load_test 10 15        # 3 nodes, 10 messages, 15s wait"
    echo ""
    echo "Prerequisites:"
    echo "  - Corrosion agents must be running"
    echo "  - Run from the project root directory"
}

# Handle help flag
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

# Run main function
main
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Setup and Dependencies
```bash
# Initial setup
mix setup
# Individual asset setup if needed
mix assets.setup
mix assets.build
```

### Running the Application

**IMPORTANT**: CorroPort requires Corrosion database agents to be running before starting Phoenix nodes.

#### Quick Start - Local Cluster Development
```bash
# 1. Start corrosion agents (database layer)
./scripts/corrosion-start.sh 3

# 2. Start Phoenix cluster (application layer)
./scripts/dev-cluster-iex.sh --verbose 3

# When done, stop everything:
# Ctrl-C to stop Phoenix cluster
./scripts/corrosion-stop.sh
```

#### Corrosion Agent Management
```bash
# Start N corrosion agents in background
./scripts/corrosion-start.sh           # Default: 3 agents
./scripts/corrosion-start.sh 5         # Start 5 agents
./scripts/corrosion-start.sh --verbose # Start with log locations

# Stop all corrosion agents
./scripts/corrosion-stop.sh

# View agent logs
tail -f logs/corrosion-node1.log
tail -f logs/corrosion-node2.log
```

#### Phoenix Application Startup
```bash
# Single node (after starting corrosion agent)
NODE_ID=1 ./scripts/dev-start.sh

# Multi-node cluster with iex (interactive on node 1)
./scripts/dev-cluster-iex.sh 3
./scripts/dev-cluster-iex.sh --verbose 3    # With background node logs

# Alternative Mix tasks (legacy, may need updates)
mix cluster.start
mix cluster.start --nodes 5
mix cluster.stop
```

### Testing
```bash
# Run tests
mix test

# Generate documentation
mix docs
```

### Build and Assets
```bash
# Build assets for production
mix assets.deploy
```

### Analytics Demonstration
```bash
# Automated analytics demo (recommended)
./scripts/analytics-demo.sh

# Custom demo with 3 nodes, 5 messages
./scripts/analytics-demo.sh 3 my_experiment 5 15

# Quick 2-node demo
./scripts/analytics-demo.sh 2

# See all options
./scripts/analytics-demo.sh --help
```

### API Testing
```bash
# Start analytics aggregation
curl -X POST http://localhost:4001/api/analytics/aggregation/start \
  -H "Content-Type: application/json" \
  -d '{"experiment_id": "test_exp"}'

# Send test message
curl -X POST http://localhost:4001/api/messages/send \
  -H "Content-Type: application/json" \
  -d '{"content": "API test message"}'

# Check aggregation status
curl http://localhost:4001/api/analytics/aggregation/status | jq

# Get experiment results
curl http://localhost:4001/api/analytics/experiments/test_exp/summary | jq
```

### Gossip Analytics
```elixir
# In IEx console - check message reception statistics
CorroPort.AckSender.get_all_reception_stats()

# Find messages received multiple times via gossip
CorroPort.AckSender.get_duplicate_receptions(2)

# Check stats for specific message
CorroPort.AckSender.get_message_stats("message_pk_here")
```

## Architecture Overview

CorroPort is an Elixir Phoenix application that provides a web interface for monitoring and interacting with Corrosion database clusters. Corrosion is a SQLite-based distributed database.

### Two-Layer Architecture

The system runs as **two independent layers** that must both be running:

1. **Corrosion Layer** (Database/Storage)
   - Runs as separate `corrosion agent` processes
   - Handles data replication, gossip protocol, and SQLite storage
   - Exposes HTTP API on ports 8081, 8082, 8083, etc.
   - Exposes QUIC gossip on ports 8787, 8788, 8789, etc.
   - Started with: `./scripts/corrosion-start.sh`

2. **CorroPort Layer** (Phoenix/Web UI)
   - Elixir/Phoenix application nodes
   - Connects to Corrosion agents via HTTP API
   - Provides web interface and real-time monitoring
   - Runs on ports 4001, 4002, 4003, etc.
   - Started with: `./scripts/dev-cluster-iex.sh`

**Key Point**: Corrosion agents must be running **before** starting Phoenix nodes. Phoenix will fail to start if it cannot connect to its Corrosion agent.

### Core Components

**Domain Modules (Clean Architecture)**
- `CorroPort.NodeDiscovery` - DNS-based expected node discovery
- `CorroPort.ClusterMembership` - CLI-based active member tracking  
- `CorroPort.MessagePropagation` - Message sending and acknowledgment tracking
- `CorroPort.ClusterSystemInfo` - System information via Corrosion API

**Legacy Modules (Being Refactored)**
- `CorroPort.CorroSubscriber` - Message subscription and acknowledgment sending
- `CorroPort.AckTracker` - Acknowledgment state management
- `CorroPort.AckSender` - HTTP acknowledgment sender with gossip deduplication
- `CorroPort.CLIMemberStore` - CLI member data caching

**API Layer**
- `CorroPort.CorroClient` - Low-level HTTP client for Corrosion API
- `CorroPort.ClusterAPI` - High-level cluster information queries

**Web Layer**
- `CorroPortWeb.ClusterLive` - Main cluster monitoring LiveView
- `CorroPortWeb.MessagesLive` - Message history and debugging
- Various component modules for UI elements

### Data Flow

1. **Node Discovery**: DNS queries discover expected cluster nodes
2. **Membership Tracking**: CLI commands track active Corrosion members
3. **System Monitoring**: API queries provide cluster state and message counts
4. **Real-time Updates**: PubSub broadcasts state changes to LiveViews
5. **Message Propagation**: Nodes send test messages and track acknowledgments

### Gossip Deduplication and Reception Tracking

**Problem**: In a gossip protocol, nodes receive the same message multiple times from different peers. Each reception would trigger a duplicate acknowledgment without deduplication.

**Solution**: `AckSender` implements in-memory deduplication with reception tracking:

**Features**:
- **ETS Cache**: Tracks `{message_pk, reception_count, first_seen, last_seen}` for each received message
- **Automatic Deduplication**: Only sends acknowledgment on first message reception
- **Gossip Analytics**: Tracks how many times each message arrives via gossip (heatmap data)
- **Automatic Cleanup**: Purges entries older than 24 hours every hour

**Query API** (`lib/corro_port/ack_sender.ex`):
```elixir
# Get stats for specific message
AckSender.get_message_stats(message_pk)

# Get all reception data (for heatmap visualization)
AckSender.get_all_reception_stats()

# Find messages with high gossip redundancy
AckSender.get_duplicate_receptions(min_count \\ 2)
```

**Data Structure**:
```elixir
%{
  message_pk: "msg123",
  reception_count: 5,        # Received 5 times via gossip
  first_seen: ~U[2025-01-01 10:00:00Z],
  last_seen: ~U[2025-01-01 10:00:15Z]
}
```

**Behavior**:
- First reception → Send acknowledgment, log "First reception"
- Subsequent receptions → Skip acknowledgment, log "Duplicate reception #N (via gossip)"

**Performance**: Fast ETS lookups with `:read_concurrency` for high-throughput scenarios

### Configuration

**Node Configuration**
- Each node has a unique `NODE_ID` (1, 2, 3, etc.)
- Phoenix runs on ports 4001, 4002, 4003, etc.
- Corrosion API runs on ports 8081, 8082, 8083, etc.
- Corrosion gossip runs on ports 8787, 8788, 8789, etc.

**Environment Variables**
- `NODE_ID` - Node identifier for multi-node setups
- Configuration managed in `lib/corro_port/node_config.ex`

### Testing Multi-Node Clusters

The application is designed for multi-node cluster testing:

1. Start 3-node cluster: `./scripts/dev-cluster-iex.sh --verbose 3`
2. Access nodes at:
   - Node 1: http://localhost:4001/cluster
   - Node 2: http://localhost:4002/cluster  
   - Node 3: http://localhost:4003/cluster
3. Send test messages and observe acknowledgment propagation
4. Use "Send Message" button to test cross-node communication
5. Monitor real-time updates in the web interface

### Key Files for Understanding

- `lib/corro_port/application.ex` - Application supervision tree
- `lib/corro_port_web/live/cluster_live.ex` - Main monitoring interface
- `lib/corro_port/corro_client.ex` - Database client implementation
- `lib/corro_port/cluster_api.ex` - High-level cluster queries
- `scripts/dev-cluster.sh` - Multi-node development setup

### Development Notes

- LiveViews use PubSub for real-time updates without polling
- Error handling focuses on graceful degradation when nodes are unavailable
- All HTTP clients use configurable timeouts and retry logic
- The application can run in single-node mode but is optimized for clusters

## LiveView Module Responsibilities

**IMPORTANT**: Do not confuse these two main LiveView modules:

### IndexLive (`/` route)
- **Purpose**: Message propagation testing and geographic visualization
- **Key Features**: 
  - "Send Message" button for testing database change propagation
  - "Reset Tracking" functionality
  - Real-time acknowledgment tracking with colored map regions
  - MessagePropagation subscription and interaction
- **URL**: `http://localhost:4001/` (root)
- **Nav Tab**: "Geographic Distribution" (propagation)

### ClusterLive (`/cluster` route)  
- **Purpose**: Comprehensive cluster health monitoring and node connectivity
- **Key Features**:
  - Cluster summary statistics (Expected/Active nodes)
  - System health monitoring (API health, message counts)
  - CLI member tables and debugging information
- **URL**: `http://localhost:4001/cluster`
- **Nav Tab**: "Cluster Status"

### Quick Reference
- **For message propagation features** → IndexLive
- **For cluster monitoring features** → ClusterLive
- **When in doubt**, check the router.ex routes and page_title assigns

This distinction is critical since both modules handle similar data sources but serve different user workflows.

## Development Guidelines

- Use Tidewave tools if possible before resorting to unix tools
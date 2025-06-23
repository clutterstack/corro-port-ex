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
```bash
# Start single node for development
./scripts/dev-start.sh
# Or with specific node ID
NODE_ID=1 ./scripts/dev-start.sh

# Start 3-node cluster (recommended for testing)
./scripts/dev-cluster.sh
# Or custom number of nodes
./scripts/dev-cluster.sh --nodes 5

# Alternative Mix tasks
mix cluster.start
mix cluster.start --nodes 5

# Stop cluster
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

## Architecture Overview

CorroPort is an Elixir Phoenix application that provides a web interface for monitoring and interacting with Corrosion database clusters. Corrosion is a SQLite-based distributed database.

### Core Components

**Domain Modules (Clean Architecture)**
- `CorroPort.NodeDiscovery` - DNS-based expected node discovery
- `CorroPort.ClusterMembership` - CLI-based active member tracking  
- `CorroPort.MessagePropagation` - Message sending and acknowledgment tracking
- `CorroPort.ClusterSystemInfo` - System information via Corrosion API

**Legacy Modules (Being Refactored)**
- `CorroPort.CorroSubscriber` - Message subscription and acknowledgment sending
- `CorroPort.AckTracker` - Acknowledgment state management
- `CorroPort.AckSender` - HTTP acknowledgment sender
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

## Development Guidelines

- Use Tidewave tools if possible before resorting to unix tools
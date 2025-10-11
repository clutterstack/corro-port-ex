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

**Recommended: All-in-one cluster startup (overmind in daemon mode, no tmux)**
```bash
# Start integrated cluster (corrosion via overmind + Phoenix, node 1 in foreground with iex)
./scripts/overmind-start.sh 3          # Start 3-node cluster
./scripts/overmind-start.sh 5          # Start 5-node cluster

# Each node's corrosion runs via overmind daemon (enables bootstrap config editing in NodeLive)
# Node 1 Phoenix runs in foreground with iex shell (only Elixir logs shown)
# Nodes 2+ Phoenix run in background as simple processes
# Ctrl-C stops all nodes automatically

# View all logs
tail -f logs/node1-corrosion.log       # Node 1 corrosion logs
tail -f logs/node1-overmind.log        # Node 1 overmind logs
tail -f logs/node2-phoenix.log         # Node 2 Phoenix logs
tail -f logs/node3-corrosion.log       # Node 3 corrosion logs

# Manual cleanup if needed
./scripts/cluster-stop.sh
```

**Build Directory Safety:**
The `overmind-start.sh` script avoids build directory lock contention by:
- Pre-compiling the application once before starting any nodes (`mix compile` at line 195)
- All nodes share the same `_build` directory but only read from it (no concurrent compilation)
- Nodes start sequentially after compilation completes, running `mix phx.server` (not recompiling)

**Alternative: Separate corrosion and Phoenix startup**
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

### Module Documentation Notes

- `CorroPort.MessagesAPI` moduledoc now clarifies that the module sits on top of the `node_messages` table to handle persistence, ack tracking, and analytics wiring. Treat it as the single entry point for sending/reading replicated messages.
- `CorroPort.CLIClusterData` moduledoc documents the GenServer that shells out to `corro_cli`, caches the CLI member list, and pushes `{:cli_members_updated, ...}` events to LiveViews.
- `CorroPort.AnalyticsAggregator` moduledoc documents the current local-first aggregation strategy (short TTL cache, PubSub broadcasts). Remote polling helpers remain, but they are intentionally dormant until remote Corrosion APIs are stable.
- `CorroPort.NodeNaming` moduledoc explicitly spells out the region-extraction behaviour and return values (`"unknown"` vs `"invalid"`).
- `CorroPortWeb.Layouts` moduledoc example demonstrates the required `current_scope` assign when calling `<Layouts.app …>` from LiveViews.
- `CorroPort.AckHttp` moduledoc covers the shared Req configuration, endpoint parsing, and logging conventions used by every outbound acknowledgment.
- `CorroPort.PubSubAckTester` moduledoc documents the cluster test broadcast flow, including request payload structure and tracking prerequisites.
- `CorroPort.PubSubAckListener` moduledoc explains the Phoenix.PubSub subscription loop, supervised task hand-off, and self-origin filtering rules.
- `CorroPort.PubSubAckTaskSupervisor` moduledoc clarifies why outbound PubSub ack jobs run under a dedicated `Task.Supervisor`.

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

**Cluster Data Sources**
- `CorroPort.DNSLookup` - Fetches expected nodes from Fly.io DNS (or dev fallback) and normalises the results for LiveViews
- `CorroPort.CLIClusterData` - GenServer that shells out to `corro_cli`, caches member data, and emits PubSub updates consumed by `ClusterLive`
- `CorroPort.LocalNode` - Surface area for local node ID, region, ports, and environment metadata used across the UI and analytics

**Messaging & Acknowledgments**
- `CorroPort.MessagesAPI` - High-level facade for inserting messages into `node_messages` and wiring ack/analytics hooks
- `CorroPort.AckTracker` - ETS-backed tracker for the latest message, acknowledgment status, and experiment linkage
- `CorroPort.AckSender` - Subscription listener that deduplicates gossip receptions and posts HTTP acknowledgments (see Gossip Analytics below)
- `CorroPort.AckDiagnostics` - IEx helper module that inspects ack pipelines end-to-end when debugging issues
- `CorroPort.AckHttp` - Shared Req client and endpoint utilities used by both gossip-driven and PubSub-driven acknowledgment flows
- `CorroPort.PubSubAckTester` - Emits `"pubsub_ack_test"` broadcasts to kick off cluster-wide acknowledgment drills
- `CorroPort.PubSubAckListener` - Subscribes to the test topic and posts HTTP acknowledgments back to the originator via supervised tasks
- `CorroPort.PubSubAckTaskSupervisor` - Supervises each asynchronous HTTP ack job triggered by the PubSub listener

**Connectivity & Configuration**
- `CorroPort.ConnectionManager` - Centralised creation of Corrosion HTTP connections (standard and subscription)
- `CorroPort.NodeConfig` - Single source of truth for node-specific port assignments, environment flags, and file paths
- `CorroPort.ConfigManager` - Runtime bootstrap editing plus corrosion restart coordination (publishes `"corrosion_lifecycle"` events)
- `CorroPort.ClusterConfigCoordinator` - Broadcasts bootstrap updates to every Phoenix node for coordinated updates
- `CorroPort.ConfigSubscriber` - Applies cluster bootstrap updates received over PubSub
- `CorroPort.DevClusterConnector` - Connects dev BEAM nodes to each other automatically when running locally

**Analytics Pipeline**
- `CorroPort.Analytics` / `CorroPort.AnalyticsStorage` - Ecto context + persistence for experiment events, metrics, and topology snapshots
- `CorroPort.AnalyticsAggregator` - Orchestrates experiment aggregation, caches results with a short TTL, and broadcasts `analytics:*` messages
- `CorroPort.SystemMetrics` - Collects per-node runtime metrics and exposes experiment-scoped counters

**Subscriptions & Helpers**
- `CorroPort.CorroSubscriber` - Supervises the Corrosion subscription, coordinating restarts with `ConfigManager`
- `CorroPort.RegionExtractor` / `CorroPort.NodeNaming` - Canonical helpers for converting identifiers into Fly regions for UI display
- `CorroPort.ClusterMemberPresenter` - Presentation transforms applied to CLI member maps before rendering

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

### Corrosion Restart Coordination

**Problem**: Restarting Corrosion while subscriptions are active creates race conditions:
- CorroSubscriber tries to reconnect before Corrosion is fully initialised
- Subscription database creation fails (unable to open database file errors)
- Connection refused errors from premature reconnection attempts

**Solution**: `ConfigManager` and `CorroSubscriber` coordinate via PubSub on the `"corrosion_lifecycle"` topic.

#### Restart Lifecycle

When `ConfigManager.restart_corrosion/0` is called:

1. **Pre-restart notification** - Broadcasts `{:corrosion_restarting}` to all subscribers
2. **Grace period** - Waits 500ms for active subscriptions to gracefully close
3. **Restart execution** - Executes `overmind restart corrosion` command
4. **Health check** - Polls Corrosion API until responsive (up to 15 attempts @ 1s each)
5. **Initialisation grace** - Additional 3.5s wait for subscription endpoint to stabilise
6. **Post-restart notification** - Broadcasts `{:corrosion_ready}` to resume subscriptions

#### CorroSubscriber Coordination

1. **Receives `{:corrosion_restarting}`**
   - Stops active subscription via `CorroClient.Subscriber.stop/1`
   - Sets state to `:paused_for_restart`
   - Broadcasts `{:subscription_paused_for_restart}` event

2. **Ignores disconnect/error callbacks**
   - While in `:paused_for_restart` state, ignores `{:subscription_disconnected}` and `{:subscription_error}`
   - Prevents stopped subscriber's callbacks from corrupting the coordinated state

3. **Receives `{:corrosion_ready}`**
   - Only processes if currently in `:paused_for_restart` state
   - Triggers subscription restart via `handle_continue(:start_subscription)`
   - Returns to `:connected` state once subscription is live

#### Key Implementation Details

- **PubSub Topic**: `"corrosion_lifecycle"`
- **Events**: `{:corrosion_restarting}`, `{:corrosion_ready}`
- **State Guard**: `:paused_for_restart` state prevents callback interference
- **Timing**: 500ms pause + API health check + 3.5s grace = ~18s total restart time
- **Backward Compatible**: Non-overmind setups unaffected

See module docs for `CorroPort.ConfigManager` and `CorroPort.CorroSubscriber` for full details.

### Configuration

**Node Configuration**
- Each node has a unique `NODE_ID` (1, 2, 3, etc.)
- Phoenix runs on ports 4001, 4002, 4003, etc.
- Corrosion API runs on ports 8081, 8082, 8083, etc.
- Corrosion gossip runs on ports 8787, 8788, 8789, etc.

**Environment Variables**
- `NODE_ID` - Node identifier for multi-node setups
- Configuration managed in `lib/corro_port/node_config.ex`

**Corrosion Configuration Architecture**

The project uses a canonical/runtime config split for safe runtime editing with easy fallback:

```
corrosion/configs/
├── canonical/      # Known-good baseline configs (committed to git)
│   ├── node1.toml
│   ├── node2.toml
│   └── node3.toml
└── runtime/        # Active configs (gitignored, editable via NodeLive UI)
    └── (auto-generated from canonical at startup)
```

**How It Works:**
- Startup scripts copy `canonical/` → `runtime/`
- Corrosion agents use runtime configs
- ConfigManager edits runtime configs only (via NodeLive UI)
- Canonical configs remain unchanged as baseline

**Fallback to Known-Good Config:**
```elixir
# Option 1: Programmatic restore
CorroPort.ConfigManager.restore_canonical_config()

# Option 2: Restart cluster (auto-restores from canonical)
./scripts/cluster-stop.sh
./scripts/overmind-start.sh 3
```

**Documentation:**
- `docs/CONFIG_MANAGEMENT.md` - Local config file management and fallback mechanisms
- `docs/BOOTSTRAP.md` - Cluster-wide distributed configuration via node_configs table, including architecture, data flow, critical bugs fixed, and race condition details

### Testing Multi-Node Clusters

The application is designed for multi-node cluster testing:

**Recommended approach (overmind in daemon mode, no tmux):**
1. Start 3-node cluster: `./scripts/overmind-start.sh 3`
   - Each node's corrosion runs via overmind daemon
   - Node 1 Phoenix runs in foreground with iex shell
   - Nodes 2-3 Phoenix run in background
   - View logs: `tail -f logs/node2-phoenix.log`
   - Edit bootstrap config via NodeLive UI at http://localhost:4001/node
2. Access nodes at:
   - Node 1: http://localhost:4001/cluster
   - Node 2: http://localhost:4002/cluster
   - Node 3: http://localhost:4003/cluster
3. Send test messages and observe acknowledgment propagation
4. Use "Send Message" button to test cross-node communication
5. Monitor real-time updates in the web interface
6. Stop all nodes: Press Ctrl+C in the terminal

**Alternative (separate corrosion/Phoenix):**
1. Start cluster: `./scripts/dev-cluster-iex.sh --verbose 3`
2. Same access URLs and testing process as above

### Key Files for Understanding

**Application Code:**
- `lib/corro_port/application.ex` - Supervision tree wiring CLI cluster data, ack pipeline, analytics, and subscriptions
- `lib/corro_port/connection_manager.ex` - Central place to obtain Corrosion connections (standard + subscription)
- `lib/corro_port/config_manager.ex` & `lib/corro_port/cluster_config_coordinator.ex` - Runtime bootstrap editing and corrosion restart orchestration
- `lib/corro_port/cluster_data_sources/cli_cluster_data.ex` - CLI membership polling, caching, and PubSub broadcasts
- `lib/corro_port_web/live/*_live.ex` - LiveView surfaces (`propagation`, `cluster`, `messages`, `node`, `analytics`, `query_console`)

**Development Scripts:**
- `scripts/overmind-start.sh` - All-in-one cluster startup (recommended, overmind in daemon mode, no tmux)
- `scripts/cluster-stop.sh` - Stop all overmind daemons and Phoenix processes
- `scripts/dev-cluster-iex.sh` - Multi-node Phoenix startup (separate from corrosion)
- `scripts/corrosion-start.sh` - Corrosion agent startup (alternative method)
- `scripts/corrosion-stop.sh` - Corrosion agent cleanup (alternative method)

### Development Notes

- LiveViews use PubSub for real-time updates without polling
- Error handling focuses on graceful degradation when nodes are unavailable
- All HTTP clients use configurable timeouts and retry logic
- The application can run in single-node mode but is optimized for clusters

## LiveView Module Responsibilities

- **PropagationLive** (`/` – nav tab "Propagation")
  - Geographic map driven by FlyMapEx and acknowledgment status.
  - Exposes "Send Message" and "Reset Tracking" actions wired to `CorroPort.MessagesAPI` / `AckTracker`.
  - Listens to `ack_events` PubSub broadcasts for real-time marker updates.

- **ClusterLive** (`/cluster` – nav tab "Cluster")
  - Aggregates DNS, CLI, and Corrosion API data into a single dashboard.
  - Uses `CorroPort.CLIClusterData` subscriptions plus `DisplayHelpers` to render summary cards and tables.
  - Provides targeted refresh actions for each data source.

- **MessagesLive** (`/messages` – nav tab "Messages")
  - Real-time feed of `node_messages` combined with acknowledgment status cards.
  - Subscribes to both `message_updates` and `ack_events` topics.
  - Surface area for ad-hoc message sends and resetting the tracker from the log view.

- **NodeLive** (`/node` – nav tab "Node")
  - Bootstrap configuration editor, corrosion restart coordination, and connectivity diagnostics.
  - Integrates `ConfigManager`, `ClusterConfigCoordinator`, and `ConnectionManager` helpers.
  - Handles both single-node and cluster-wide bootstrap updates via PubSub.

- **AnalyticsLive** (`/analytics` – nav tab "Analytics")
  - Controls experiment aggregation via `CorroPort.AnalyticsAggregator`.
  - Renders timing/system metrics and listens for `analytics:*` broadcasts per experiment.
  - Supports manual refresh cadence adjustments in the UI.

- **QueryConsoleLive** (`/query-console` – nav tab "Query Console")
  - Preset-backed SQL/API scratchpad that reuses `ConnectionManager` for Corrosion sessions.
  - Useful for inspecting `__corro_members`, `node_messages`, and analytics tables without leaving the UI.

### Quick Reference
- Propagation map & acknowledgement tracking → `PropagationLive`
- Cluster inventory and DNS/CLI/API comparisons → `ClusterLive`
- Message history plus ack health → `MessagesLive`
- Bootstrap + corrosion lifecycle management → `NodeLive`
- Experiment dashboards and analytics control → `AnalyticsLive`
- Ad-hoc Corrosion SQL/API queries → `QueryConsoleLive`

Router source of truth: `lib/corro_port_web/router.ex`.

## Development Guidelines


- Use Tidewave tools if possible before resorting to unix tools
- Use `CorroPort.ConnectionManager` helpers (`get_connection/0`, `get_subscription_connection/0`) instead of building raw Corrosion URLs in new code.
- Source cluster data through the existing abstractions (`CorroPort.CLIClusterData`, `CorroPort.DNSLookup`, `CorroPort.LocalNode`) so the LiveViews keep receiving consistent shapes.
- Use `CorroClient.transaction/2` to make changes to the Corrosion database and `CorroClient.query/2` to read from it.


## Prod deployment

Deployed on Fly.io. VMs are built from the Dockerfile in this project.

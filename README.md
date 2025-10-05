# CorroPort

A Phoenix LiveView application for monitoring and interacting with Corrosion database clusters. Corrosion is a SQLite-based distributed database with gossip protocol replication.

## Architecture

CorroPort runs as **two independent layers**:

1. **Corrosion Layer** (Database/Storage) - Separate agent processes handling data replication
2. **CorroPort Layer** (Phoenix/Web UI) - Elixir application providing monitoring and interaction

**Important**: Corrosion agents must be running before starting Phoenix nodes.

## Development Setup

### Prerequisites

1. Elixir and Phoenix
2. Corrosion binary for your platform (place in `corrosion/corrosion-mac`)
3. Canonical config files are included in `corrosion/configs/canonical/`
   - Runtime configs are auto-generated at startup from canonical configs

### Quick Start - Recommended Workflow

**All-in-One Startup (Simplest - No tmux)**

```bash
# Start integrated cluster (corrosion + Phoenix)
./scripts/overmind-start.sh 3

# Node 1 runs in foreground with iex shell (only Elixir logs shown)
# Nodes 2-3 run in background as simple processes
# Ctrl-C stops all nodes automatically

# Access the web interface:
#    Node 1: http://localhost:4001
#    Node 2: http://localhost:4002
#    Node 3: http://localhost:4003

# View background node logs:
tail -f logs/node2-phoenix.log
tail -f logs/node3-corrosion.log

# Show corrosion logs in terminal (optional):
./scripts/overmind-start.sh 3 --show-corrosion
```

**Alternative: Separate Corrosion and Phoenix Startup**

```bash
# 1. Start Corrosion agents (database layer)
./scripts/corrosion-start.sh 3

# 2. Start Phoenix cluster (application layer)
./scripts/dev-cluster-iex.sh --verbose 3

# 3. Access the web interface (same URLs as above)

# 4. When done:
#    Press Ctrl-C to stop Phoenix cluster
./scripts/corrosion-stop.sh
```

### Corrosion Agent Management

```bash
# Start agents
./scripts/corrosion-start.sh           # Start 3 agents (default)
./scripts/corrosion-start.sh 5         # Start 5 agents
./scripts/corrosion-start.sh --verbose # Show log file locations

# View agent logs
tail -f logs/corrosion-node1.log
tail -f logs/corrosion-node2.log

# Stop agents
./scripts/corrosion-stop.sh            # Gracefully stop all agents

# Check agent status
ps aux | grep corrosion | grep agent
lsof -i :8081-8083                     # Check API ports
```

### Phoenix Application Startup

```bash
# Interactive cluster (node 1 with iex, others in background)
./scripts/dev-cluster-iex.sh 3
./scripts/dev-cluster-iex.sh --verbose 3

# Single node (requires corrosion agent on port 8081)
NODE_ID=1 mix phx.server

# Manual multi-node setup (each in separate terminal)
# Requires corrosion agents already running
NODE_ID=1 mix phx.server   # Terminal 1
NODE_ID=2 mix phx.server   # Terminal 2
NODE_ID=3 mix phx.server   # Terminal 3
```

### Port Configuration

Each node uses consistent port offsets:

| Component | Node 1 | Node 2 | Node 3 | Pattern |
|-----------|--------|--------|--------|---------|
| Phoenix Web | 4001 | 4002 | 4003 | `4000 + node_id` |
| Phoenix API | 5001 | 5002 | 5003 | `5000 + node_id` |
| Corrosion API | 8081 | 8082 | 8083 | `8080 + node_id` |
| Corrosion Gossip | 8787 | 8788 | 8789 | `8786 + node_id` |

### Access Points

**Web Interface**
- Node 1: http://localhost:4001
  - Geographic Distribution: http://localhost:4001/
  - Cluster Status: http://localhost:4001/cluster
- Node 2: http://localhost:4002
- Node 3: http://localhost:4003

**Corrosion API**
- Node 1: http://127.0.0.1:8081/v1/cluster/info
- Node 2: http://127.0.0.1:8082/v1/cluster/info
- Node 3: http://127.0.0.1:8083/v1/cluster/info

### Cleanup

```bash
# Stop all nodes (if using overmind-start.sh)
# Press Ctrl-C in the terminal
# Or manually: ./scripts/cluster-stop.sh

# Stop Phoenix nodes (if using separate startup)
# Press Ctrl-C in terminal running dev-cluster-iex.sh
# Or kill individual processes if running manually

# Stop Corrosion agents (if using separate startup)
./scripts/corrosion-stop.sh

# Clean up databases (optional - removes all data)
rm corrosion/dev-node*.db*
rm analytics/analytics_node*.db*

# Clean up logs
rm logs/corrosion-node*.log
rm logs/node*.log
```

## Configuration Management

CorroPort uses a **canonical/runtime config split** for safe runtime editing with easy fallback:

```
corrosion/configs/
├── canonical/      # Known-good baseline configs (committed to git)
│   ├── node1.toml
│   ├── node2.toml
│   └── node3.toml
└── runtime/        # Active configs (gitignored, auto-generated)
    └── (copied from canonical at startup)
```

### How It Works

1. **Startup**: Scripts copy `canonical/` → `runtime/`
2. **Runtime Editing**: Edit bootstrap configs via NodeLive UI at `/node`
   - Changes are written to runtime configs only
   - Canonical configs remain unchanged as baseline
3. **Fallback**: Restore known-good config when needed

### Fallback to Known-Good Config

**Option 1: Programmatic restore**
```elixir
# In IEx console
CorroPort.ConfigManager.restore_canonical_config()
CorroPort.ConfigManager.restart_corrosion()
```

**Option 2: Restart cluster (auto-restores)**
```bash
./scripts/cluster-stop.sh
./scripts/overmind-start.sh 3  # Automatically copies canonical → runtime
```

**Option 3: Manual**
```bash
cp corrosion/configs/canonical/node1.toml corrosion/configs/runtime/node1.toml
```

### Testing the Fallback Mechanism

```bash
./scripts/test-config-fallback.sh
```

See [`docs/CONFIG_MANAGEMENT.md`](docs/CONFIG_MANAGEMENT.md) for complete documentation.
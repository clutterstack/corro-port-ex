# CorroPort

## Development Setup

### Prerequisites

1. Elixir and Phoenix
2. [Overmind](https://github.com/DarthSim/overmind) for process management
3. Corrosion binary for your platform (place in `corrosion/corrosion-mac`)

### Quick Start

```bash
# Setup development environment
./scripts/setup.sh

# Start a single node
./scripts/dev-start.sh

# Start a 3-node cluster
./scripts/dev-cluster.sh

# Start a custom cluster
./scripts/dev-cluster.sh --nodes 5

# Alternative using Mix tasks
mix cluster.start
mix cluster.start --nodes 5
```

### Manual Development

If you prefer more control:

```bash
# Terminal 1 - Node 1
NODE_ID=1 ./scripts/dev-start.sh

# Terminal 2 - Node 2  
NODE_ID=2 ./scripts/dev-start.sh

# Terminal 3 - Node 3
NODE_ID=3 ./scripts/dev-start.sh
```

### Access Points

- **Node 1**: http://localhost:4001/cluster
- **Node 2**: http://localhost:4002/cluster  
- **Node 3**: http://localhost:4003/cluster

### Cleanup

```bash
# Stop all nodes and clean up
mix cluster.stop

# Or manually
pkill -f "corrosion.*agent"
rm corrosion/node*.db*
rm corrosion/config-node*.toml
```
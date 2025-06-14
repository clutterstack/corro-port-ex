# Testing the Corrosion Cluster

## Prerequisites

1. Make sure you have `corrosion-mac` binary in the `corrosion/` directory
2. Ensure the `corrosion/wrapper.sh` script is executable:
   ```bash
   chmod +x corrosion/wrapper.sh
   ```

## Quick Test

### 1. Start a 3-node cluster
```bash
mix cluster.start
```

This will:
- Start nodes 2 and 3 in the background
- Start node 1 in the foreground with IEx
- Display connection information

### 2. Test the cluster

In the IEx session (node 1), you can:

```elixir
# Check the current node status
CorroPort.CorroStartup.get_status()

# Check the node configuration
CorroPort.NodeConfig.app_node_config()

# View the generated Corrosion config
File.read!(CorroPort.NodeConfig.get_config_path()) |> IO.puts()

# Connect to other Elixir nodes (if needed for future features)
Node.connect(:"corro2@#{:inet.gethostname() |> elem(1)}")
Node.list()
```

### 3. Test Phoenix endpoints

Open these URLs in your browser:
- Node 1: http://localhost:4001
- Node 2: http://localhost:4002  
- Node 3: http://localhost:4003

### 4. Stop the cluster

Press `Ctrl+C` twice in the IEx session, or run:
```bash
mix cluster.stop
```

## Advanced Testing

### Start with custom number of nodes
```bash
mix cluster.start --nodes 5
```

### Start with custom prefix
```bash
mix cluster.start --prefix myapp --nodes 2
```

### Manual node startup (for debugging)
```bash
# Terminal 1
NODE_ID=1 iex --sname corro1 -S mix phx.server

# Terminal 2  
NODE_ID=2 iex --sname corro2 -S mix phx.server
```

## Expected Behavior

1. **Node 1** should start with an empty bootstrap list (becomes seed)
2. **Nodes 2+** should bootstrap from Node 1's gossip port (8787)
3. Each node should have its own database file: `corrosion/node1.db`, `corrosion/node2.db`, etc.
4. Each node should generate its own config: `corrosion/config-node1.toml`, etc.
5. Phoenix should be accessible on different ports
6. Corrosion logs should appear with node identifiers

## Troubleshooting

### Check if Corrosion is running
```bash
ps aux | grep corrosion
```

### Check generated configs
```bash
ls -la corrosion/config-node*.toml
cat corrosion/config-node1.toml
```

### Check database files
```bash
ls -la corrosion/node*.db*
```

### Manual cleanup
```bash
mix cluster.stop
# or manually:
pkill -f corrosion
rm corrosion/node*.db*
rm corrosion/config-node*.toml
```
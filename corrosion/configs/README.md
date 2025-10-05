# Corrosion Configuration Directory Structure

This directory contains both canonical and runtime configuration files for Corrosion nodes.

## Directory Structure

```
corrosion/configs/
├── canonical/          # Known-good baseline configs (committed to git)
│   ├── node1.toml
│   ├── node2.toml
│   └── node3.toml
└── runtime/            # Active runtime configs (gitignored)
    ├── node1.toml
    ├── node2.toml
    └── node3.toml
```

## How It Works

### Startup (corrosion-start.sh, overmind-start.sh)
1. Copies canonical configs to runtime directory
2. Starts Corrosion agents using runtime configs
3. Runtime configs can be edited via NodeLive UI

### Runtime Editing (NodeLive UI)
1. ConfigManager edits only runtime configs
2. Restarts Corrosion to apply changes
3. Canonical configs remain unchanged

### Fallback
1. Delete or move problematic runtime config
2. Restart cluster - canonical config will be copied to runtime
3. Known-good baseline is restored

## For N-Node Clusters

Startup scripts automatically generate runtime configs for nodes 4-10 based on the 3-node pattern.
You can create canonical configs for nodes 4+ if you want custom baseline configs.

## Production

In production (fly.io), ConfigManager generates configs dynamically based on environment variables.
This canonical/runtime split applies only to development environments.

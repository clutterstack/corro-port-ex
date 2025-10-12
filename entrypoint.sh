#!/bin/bash

# Production entrypoint for fly.io deployment
# Generates the final Corrosion config with dynamic values

set -e

echo "🚀 Starting CorroPort production setup..."

# Wipe volume clean for ephemeral state
echo "🧹 Wiping volume clean (ephemeral state)..."
rm -rf /opt/data/*
echo "✅ Volume cleaned"

# Ensure we have required environment variables
if [ -z "$FLY_APP_NAME" ] || [ -z "$FLY_PRIVATE_IP" ] || [ -z "$FLY_MACHINE_ID" ]; then
    echo "❌ Missing required fly.io environment variables:"
    echo "   FLY_APP_NAME: $FLY_APP_NAME"
    echo "   FLY_PRIVATE_IP: $FLY_PRIVATE_IP"
    echo "   FLY_MACHINE_ID: $FLY_MACHINE_ID"
    exit 1
fi

echo "📋 Production Configuration:"
echo "   App: $FLY_APP_NAME"
echo "   Machine: $FLY_MACHINE_ID"
echo "   Private IP: $FLY_PRIVATE_IP"

# Ensure database directories exist
echo "📁 Creating database directories..."
mkdir -p /opt/data/corrosion
mkdir -p /opt/data/analytics

# Generate the final corrosion config with dynamic values
cat > /app/corrosion.toml << EOF
# Generated production config for fly.io machine: $FLY_MACHINE_ID
[db]
path = "/opt/data/corrosion/state.db"
schema_paths = ["/app/schemas"]

[gossip]
addr = "[$FLY_PRIVATE_IP]:8787"
bootstrap = ["$FLY_APP_NAME.internal:8787"]
plaintext = true
max_mtu = 1372
disable_gso = true

[api]
addr = "[::]:8081"

[admin]
path = "/app/admin.sock"

[telemetry]
prometheus.addr = "0.0.0.0:9090"

[log]
colors = false
EOF

echo "✅ Corrosion config generated at /app/corrosion.toml"

# Clean up any lost+found directories that might be created by the filesystem
rm -rf '/opt/data/lost+found'

echo "✅ Database directories prepared:
   Corrosion: /opt/data/corrosion/
   Analytics: /opt/data/analytics/"

echo "🗄️  Running database migrations..."
/app/bin/corro_port eval "CorroPort.Release.migrate()"
echo "✅ Migrations complete"

echo "🔧 Starting services with Overmind..."

# Switch to corrosion user and start overmind
exec "$@"
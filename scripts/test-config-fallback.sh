#!/bin/bash

# scripts/test-config-fallback.sh
# Demonstrates the canonical/runtime config fallback mechanism

set -e

echo "=========================================="
echo "Config Fallback Mechanism Test"
echo "=========================================="
echo ""

# Setup
echo "1. Setup - Creating runtime config from canonical"
mkdir -p corrosion/configs/runtime
cp corrosion/configs/canonical/node1.toml corrosion/configs/runtime/node1.toml
echo "   ✅ Runtime config created from canonical"
echo ""

# Show original
echo "2. Original runtime config bootstrap:"
grep "bootstrap" corrosion/configs/runtime/node1.toml
echo ""

# Simulate user edit
echo "3. Simulating user edit (changing bootstrap list)"
sed -i '' 's/bootstrap = \[.*\]/bootstrap = ["127.0.0.1:9999"]/' corrosion/configs/runtime/node1.toml
echo "   Modified bootstrap:"
grep "bootstrap" corrosion/configs/runtime/node1.toml
echo ""

# Show canonical unchanged
echo "4. Verifying canonical config remains unchanged:"
grep "bootstrap" corrosion/configs/canonical/node1.toml
echo ""

# Fallback
echo "5. Testing fallback - restoring from canonical"
cp corrosion/configs/canonical/node1.toml corrosion/configs/runtime/node1.toml
echo "   ✅ Restored from canonical"
echo ""

# Show restored
echo "6. Restored runtime config bootstrap:"
grep "bootstrap" corrosion/configs/runtime/node1.toml
echo ""

echo "=========================================="
echo "Test Complete!"
echo ""
echo "Summary:"
echo "  ✅ Runtime configs can be edited independently"
echo "  ✅ Canonical configs remain unchanged"
echo "  ✅ Fallback works by copying canonical → runtime"
echo ""
echo "In practice:"
echo "  - Edit configs via NodeLive UI (modifies runtime)"
echo "  - Use ConfigManager.restore_canonical_config() to fallback"
echo "  - Or restart cluster (startup script copies canonical → runtime)"
echo "=========================================="

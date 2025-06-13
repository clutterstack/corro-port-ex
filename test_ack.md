# Start tracking a message
message_data = %{pk: "test_123", timestamp: "2025-06-11T10:00:00Z", node_id: "node1"}
CorroPort.AckTracker.track_latest_message(message_data)

# Add some acknowledgments
CorroPort.AckTracker.add_acknowledgment("node2")
CorroPort.AckTracker.add_acknowledgment("node3")

# Check status
CorroPort.AckTracker.get_status()

```
# Should show something like:
# %{
#   latest_message: %{pk: "test_123", timestamp: "2025-06-11T10:00:00Z", node_id: "node1"},
#   acknowledgments: [%{node_id: "node2", timestamp: ~U[...]}, %{node_id: "node3", timestamp: ~U[...]}],
#   expected_nodes: ["node2", "node3"],  # (assuming we're running as node1)
#   ack_count: 2,
#   expected_count: 2
# }
```


# 1. First, track a message in the AckTracker
message_data = %{pk: "node1_test123", timestamp: "2025-06-11T10:00:00Z", node_id: "node1"}
CorroPort.AckTracker.track_latest_message(message_data)

# 2. Check the current status
CorroPort.AckTracker.get_status()

# 3. Now test the API endpoint using curl (from terminal):
# curl -X POST http://localhost:4001/api/acknowledge \
#   -H "Content-Type: application/json" \
#   -d '{
#     "message_pk": "node1_test123",
#     "ack_node_id": "node2",
#     "message_timestamp": "2025-06-11T10:00:00Z"
#   }'

# 4. Or test using Req from IEx:
Req.post("http://localhost:#{Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port]}/api/acknowledge", 
  json: %{
    "message_pk" => "node1_test123",
    "ack_node_id" => "node2", 
    "message_timestamp" => "2025-06-11T10:00:00Z"
  }
)

# 5. Check status again to see the acknowledgment
CorroPort.AckTracker.get_status()

# 6. Test the health endpoint
Req.get("http://localhost:#{Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port]}/api/acknowledge/health")

Excellent! Now let's create the `AcknowledgmentSender` that will send HTTP requests to other nodes when we receive their messages via CorroSubscriber.Now let's test the `AcknowledgmentSender`. We'll need a multi-node setup for proper testing, but we can test some parts in isolation first.

**Test commands for IEx:**

```elixir
# 1. Test node discovery logic
CorroPort.AcknowledgmentSender.test_connectivity("node2")
CorroPort.AcknowledgmentSender.test_connectivity("node3")

# 2. Test with invalid node IDs
CorroPort.AcknowledgmentSender.test_connectivity("invalid_node")
CorroPort.AcknowledgmentSender.test_connectivity("node999")

# 3. Test all connectivity (will show which nodes are reachable)
CorroPort.AcknowledgmentSender.test_all_connectivity()

# 4. Test sending an acknowledgment (this will fail if target node isn't running)
message_data = %{pk: "node2_test123", timestamp: "2025-06-11T10:00:00Z", node_id: "node2"}
CorroPort.AcknowledgmentSender.send_acknowledgment("node2", message_data)
```

**For multi-node testing, start a 3-node cluster:**

```bash
# Terminal 1 (Node 1)
NODE_ID=1 iex --sname corro1 -S mix phx.server

# Terminal 2 (Node 2) 
NODE_ID=2 iex --sname corro2 -S mix phx.server

# Terminal 3 (Node 3)
NODE_ID=3 iex --sname corro3 -S mix phx.server
```

**Then test cross-node acknowledgments:**

```elixir
# On Node 1 (localhost:4001), track a message
message_data = %{pk: "node1_test456", timestamp: "2025-06-11T10:00:00Z", node_id: "node1"}
CorroPort.AckTracker.track_latest_message(message_data)

# On Node 2 (localhost:4002), send acknowledgment to Node 1
message_data = %{pk: "node1_test456", timestamp: "2025-06-11T10:00:00Z", node_id: "node1"}
CorroPort.AcknowledgmentSender.send_acknowledgment("node1", message_data)

# Back on Node 1, check if acknowledgment was received
CorroPort.AckTracker.get_status()
```

The `AcknowledgmentSender` provides:

1. ✅ **Node Discovery**: Automatically calculates Phoenix ports from node IDs
2. ✅ **HTTP Client**: Uses Req to send acknowledgments with proper timeouts
3. ✅ **Error Handling**: Graceful handling of connection failures, timeouts, etc.
4. ✅ **Connectivity Testing**: Health check capabilities for debugging
5. ✅ **Self-Protection**: Won't send acknowledgments to itself
6. ✅ **Comprehensive Logging**: Debug and info logs for troubleshooting

**Expected behaviors:**

- ✅ Successful acknowledgment: Returns `:ok`, logs success
- ✅ Target node not running: Returns `{:error, :connection_refused}`, logs warning  
- ✅ Target node not tracking the message: Returns `:ok` (404 is treated as success)
- ✅ Network timeout: Returns `{:error, :timeout}`, logs warning
- ✅ Invalid node ID: Returns `{:error, reason}`, logs warning

Ready to test this and then integrate it with CorroSubscriber?

# Testing the Acknowledgment Integration

## Setup
1. Start a 3-node cluster:
   ```bash
   mix cluster.start --nodes 3
   ```

2. Open ClusterLive on each node:
   - Node 1: http://localhost:4001/cluster
   - Node 2: http://localhost:4002/cluster  
   - Node 3: http://localhost:4003/cluster

## Test Sequence

### 1. Test Connectivity
1. On any node, click the "Test" button in the Acknowledgment card
2. Should see connectivity results showing which nodes are reachable
3. Check the flash message for summary (e.g., "2/2 nodes reachable")

### 2. Test Message Acknowledgments
1. On Node 1, click "Send Message" button
2. Observe the Acknowledgment card should show:
   - Latest tracked message with timestamp
   - Progress bar showing 0/2 acknowledgments initially
   - Expected nodes: node2, node3 (with outline badges)

3. Wait a few seconds for CorroSubscriber to process the message on nodes 2 & 3
4. Watch the acknowledgment card update in real-time:
   - Progress bar should fill up as acknowledgments arrive
   - Node badges should turn green with checkmarks
   - Should reach 2/2 acknowledgments

### 3. Test from Different Nodes
1. Send a message from Node 2
2. Check Node 2's acknowledgment card shows tracking for the new message
3. Verify Node 1 and Node 3 automatically send acknowledgments back to Node 2

### 4. Verify CorroSubscriber Stats
1. Check the "CorroSubscriber Stats" section in the acknowledgment card
2. Should show:
   - Number of acknowledgments sent
   - Total messages processed

## Expected Behavior

**Automatic Flow:**
```
Node1 clicks "Send Message" 
→ Message inserted into Corrosion
→ CorroSubscriber on Node2/3 receives the new message
→ CorroSubscriber automatically sends HTTP acknowledgment to Node1
→ Node1's AcknowledgmentController receives the ack
→ Node1's ClusterLive updates in real-time via PubSub
```

**Real-time Updates:**
- No need to refresh the page
- Acknowledgments should appear within 1-2 seconds
- Progress bar should animate smoothly
- Node badges should update automatically

## Troubleshooting

If acknowledgments aren't working:

1. **Check CorroSubscriber logs** (look for "🤝 Sending acknowledgment"):
   ```elixir
   CorroPort.CorroSubscriber.get_status()
   ```

2. **Check AckTracker status**:
   ```elixir
   CorroPort.AckTracker.get_status()
   ```

3. **Test connectivity manually**:
   ```elixir
   CorroPort.AcknowledgmentSender.test_all_connectivity()
   ```

4. **Check if messages are being received**:
   ```elixir
   CorroPort.MessagesAPI.get_latest_node_messages()
   ```

## Success Criteria

✅ Connectivity test shows all nodes reachable  
✅ Sending message starts acknowledgment tracking  
✅ Other nodes automatically send acknowledgments  
✅ Progress bar updates in real-time  
✅ All expected acknowledgments received (2/2)  
✅ CorroSubscriber stats increment correctly
# Start tracking a message
message_data = %{pk: "test_123", timestamp: "2025-06-11T10:00:00Z", node_id: "node1"}
CorroPort.AcknowledgmentTracker.track_latest_message(message_data)

# Add some acknowledgments
CorroPort.AcknowledgmentTracker.add_acknowledgment("node2")
CorroPort.AcknowledgmentTracker.add_acknowledgment("node3")

# Check status
CorroPort.AcknowledgmentTracker.get_status()

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


# 1. First, track a message in the AcknowledgmentTracker
message_data = %{pk: "node1_test123", timestamp: "2025-06-11T10:00:00Z", node_id: "node1"}
CorroPort.AcknowledgmentTracker.track_latest_message(message_data)

# 2. Check the current status
CorroPort.AcknowledgmentTracker.get_status()

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
CorroPort.AcknowledgmentTracker.get_status()

# 6. Test the health endpoint
Req.get("http://localhost:#{Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port]}/api/acknowledge/health")
# Test with the actual NDJSON format that Corrosion CLI outputs (single line)
sample_data = ~s({"id": "46d4a93e-6281-4b8b-b2c0-1d5de80e99e4", "rtts": [0, 0, 0, 0, 0, 0], "state": {"addr": "127.0.0.1:8787", "cluster_id": 0, "last_empty_ts": null, "last_sync_ts": 7516174513346358624, "ring": 0, "ts": 7516174497280049904}})

{:ok, [member]} = CorroPort.CorrosionParser.parse_cluster_members(sample_data)

# Check enhanced fields
IO.inspect(member["short_id"])           # "46d4a93e..."
IO.inspect(member["parsed_addr"])        # "127.0.0.1:8787"
IO.inspect(member["computed_status"])    # "active"
IO.inspect(member["rtt_avg"])            # 0.0
IO.inspect(member["cluster_id"])         # 0
IO.inspect(member["formatted_last_sync_ts"]) # "2025-XX-XX XX:XX:XX UTC"

# Use utility functions
summary = CorroPort.CorrosionParser.summarize_member(member)
is_active = CorroPort.CorrosionParser.active_member?(member)
IO.inspect(summary)
IO.inspect(is_active)

# Test with multiple members (actual NDJSON format)
multi_member_data = """
{"id": "46d4a93e-6281-4b8b-b2c0-1d5de80e99e4", "rtts": [0, 0, 0, 0, 0, 0], "state": {"addr": "127.0.0.1:8787", "cluster_id": 0, "last_empty_ts": null, "last_sync_ts": 7516174513346358624, "ring": 0, "ts": 7516174497280049904}}
{"id": "another-member-uuid", "rtts": [1, 2, 1, 0, 1, 2], "state": {"addr": "127.0.0.1:8788", "cluster_id": 0, "last_empty_ts": null, "last_sync_ts": 7516174513346358624, "ring": 1, "ts": 7516174497280049904}}
"""

{:ok, members} = CorroPort.CorrosionParser.parse_cluster_members(multi_member_data)
IO.inspect(length(members))  # Should be 2

Other tests: 

## empty list (single node):

```

[info] CorroCLI: Raw output: ""
[debug] handling {:ok, ""} from task #Reference<0.0.84611.4079730995.595394561.97793>
[lib/corro_port_web/live/cluster_live.ex:74: CorroPortWeb.ClusterLive.handle_info/2]
CorroPort.CorrosionParser.parse_cluster_members(raw_output) #=> {:ok, []}

[info] ClusterLive: No cluster members found - single node setup
[lib/corro_port_web/live/cluster_live.ex:89: CorroPortWeb.ClusterLive.handle_info/2]
parsed_result #=> %{}
```
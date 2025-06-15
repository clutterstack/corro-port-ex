from https://claude.ai/chat/96b24a97-fc74-41eb-932f-a44a498a2a6a
# Test cases you can run in IEx to verify the parser handles edge cases:

# 1. Empty output (single node)
{:ok, []} = CorroPort.CorrosionParser.parse_cluster_members("")

# 2. Whitespace-only output
{:ok, []} = CorroPort.CorrosionParser.parse_cluster_members("   \n\n  \t  ")

# 3. Valid single member
valid_single = ~s({"id":"abc123","state":{"addr":"127.0.0.1:8787"}})
{:ok, [member]} = CorroPort.CorrosionParser.parse_cluster_members(valid_single)
IO.inspect(member["parsed_addr"]) # Should be "127.0.0.1:8787"

# 4. Multiple members
valid_multiple = ~s({"id":"abc123","state":{"addr":"127.0.0.1:8787"}}
{"id":"def456","state":{"addr":"127.0.0.1:8788"}})
{:ok, members} = CorroPort.CorrosionParser.parse_cluster_members(valid_multiple)
IO.inspect(length(members)) # Should be 2

# 5. Mixed valid/invalid lines (should succeed with warnings)
mixed = ~s({"id":"abc123","state":{"addr":"127.0.0.1:8787"}}
invalid json line
{"id":"def456","state":{"addr":"127.0.0.1:8788"}})
{:ok, members} = CorroPort.CorrosionParser.parse_cluster_members(mixed)
IO.inspect(length(members)) # Should be 2 (ignores invalid line)

# 6. Test the CLI integration with empty output
# Mock the CorrosionCLI to return empty string for testing:
defmodule MockCorrosionCLI do
  def cluster_members(_opts \\ []) do
    {:ok, ""}  # Simulate single node scenario
  end
end

# Then test the flow:
{:ok, raw} = MockCorrosionCLI.cluster_members()
{:ok, parsed} = CorroPort.CorrosionParser.parse_cluster_members(raw)
IO.inspect(parsed) # Should be []
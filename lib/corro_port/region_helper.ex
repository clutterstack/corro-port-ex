defmodule CorroPortWeb.RegionHelper do
  @moduledoc """
  Helper functions for extracting and processing region data from different node sources.
  """

  require Logger
  alias CorroPort.{AckTracker, NodeConfig, CorrosionParser}

  @doc """
  Extract region information from the data fetcher results.

  Returns {expected_regions, active_regions, our_regions}
  """



  def extract_regions(data) do

  Logger.debug("RegionHelper.extract_regions: Raw active members: #{inspect(data.active_members)}")
# Extract regions from active members (CLI)
  node_ids = data.active_members
  |> Enum.map(&AckTracker.member_to_node_id/1)


  regions = node_ids
  |> Enum.reject(&is_nil/1)
  |> Enum.map(&CorrosionParser.extract_region_from_node_id/1)


  active_regions = regions
  |> Enum.reject(&(&1 == "unknown"))
  |> Enum.uniq()


    # Extract regions from expected nodes (DNS)
    expected_regions =
      data.expected_nodes
      |> Enum.map(&CorrosionParser.extract_region_from_node_id/1)
      |> Enum.reject(&(&1 == "unknown"))
      |> Enum.uniq()


    # Get our local region
    local_node_id = NodeConfig.get_corrosion_node_id()
    our_region = CorrosionParser.extract_region_from_node_id(local_node_id)

    # Remove our region from list unless it's "dev"
    if our_region != "dev" do

    ^expected_regions = Enum.reject(expected_regions, &(&1 == our_region))
    ^active_regions = Enum.reject(active_regions, &(&1 == our_region))
    end

    our_regions = if our_region != "unknown", do: [our_region], else: []

    Logger.info("RegionHelper: Expected regions: #{inspect(expected_regions)}")
    Logger.info("RegionHelper: Active regions: #{inspect(active_regions)}")
    Logger.info("RegionHelper: Our regions: #{inspect(our_regions)}")

    {expected_regions, active_regions, our_regions}
  end

  @doc """
  Extract acknowledgment regions from AckTracker status.
  """
  def extract_ack_regions(ack_status) do
    regions =
      ack_status
      |> Map.get(:acknowledgments, [])
      |> Enum.map(fn ack ->
        CorrosionParser.extract_region_from_node_id(ack.node_id)
      end)
      |> Enum.reject(&(&1 == "unknown"))
      |> Enum.uniq()

    Logger.debug("regions: #{inspect(regions)}")
    regions
  end
end

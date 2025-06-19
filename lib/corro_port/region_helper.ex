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
    # Extract regions from expected nodes (DNS)
    expected_regions =
      data.expected_nodes
      |> Enum.map(&CorrosionParser.extract_region_from_node_id/1)
      |> Enum.reject(&(&1 == "unknown"))
      |> Enum.uniq()

    # Extract regions from active members (CLI)
    active_regions =
      data.active_members
      |> Enum.map(&AckTracker.member_to_node_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&CorrosionParser.extract_region_from_node_id/1)
      |> Enum.reject(&(&1 == "unknown"))
      |> Enum.uniq()

    # Get our local region
    local_node_id = NodeConfig.get_corrosion_node_id()
    our_region = CorrosionParser.extract_region_from_node_id(local_node_id)

    # Remove our region from others
    expected_regions = Enum.reject(expected_regions, &(&1 == our_region))
    active_regions = Enum.reject(active_regions, &(&1 == our_region))
    our_regions = if our_region != "unknown", do: [our_region], else: []

    Logger.debug("RegionHelper: Expected regions: #{inspect(expected_regions)}")
    Logger.debug("RegionHelper: Active regions: #{inspect(active_regions)}")
    Logger.debug("RegionHelper: Our regions: #{inspect(our_regions)}")

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

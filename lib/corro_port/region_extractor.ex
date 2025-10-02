defmodule CorroPort.RegionExtractor do
  @moduledoc """
  Graceful region extraction that always returns a list, even on errors.
  Used by domain GenServers to compute regions from their data.
  """

  @doc """
  Extract regions from a list of node IDs.
  Always returns a list, empty on error.
  In dev mode, uses full node IDs as distinct regions.
  """
  def extract_from_nodes({:ok, nodes}) when is_list(nodes) do
    if CorroPort.NodeConfig.production?() do
      # Production: extract region prefix
      nodes
      |> Enum.map(&CorroPort.NodeNaming.extract_region_from_node_id/1)
      |> Enum.reject(&(&1 in ["unknown", ""]))
      |> Enum.uniq()
    else
      # Development: use full node IDs as distinct regions
      nodes
      |> Enum.reject(&(&1 in ["unknown", ""]))
      |> Enum.uniq()
    end
  end

  def extract_from_nodes({:error, _reason}), do: []
  def extract_from_nodes(nil), do: []

  @doc """
  Extract regions from a list of cluster members.
  Always returns a list, empty on error.
  In dev mode, uses full node IDs as distinct regions.
  """
  def extract_from_members({:ok, members}) when is_list(members) do
    case CorroPort.NodeConfig.production?() do
      true ->
        # Production: extract region prefix from member data
        members
        |> Enum.map(&CorroPort.AckTracker.member_to_node_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&CorroPort.NodeNaming.extract_region_from_node_id/1)
        |> Enum.reject(&(&1 in ["unknown", ""]))
        |> Enum.uniq()

      false ->
        # Development: use full node IDs as distinct regions
        members
        |> Enum.map(&CorroPort.AckTracker.member_to_node_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1 in ["unknown", ""]))
        |> Enum.uniq()
    end
  end

  def extract_from_members({:error, _reason}), do: []
  def extract_from_members(nil), do: []

  @doc """
  Extract regions from acknowledgment data.
  Always returns a list, empty on error.
  In dev mode, uses full node IDs as distinct regions.
  """
  def extract_from_acks(acks) when is_list(acks) do
    if CorroPort.NodeConfig.production?() do
      # Production: extract region prefix
      acks
      |> Enum.map(& &1.node_id)
      |> Enum.map(&CorroPort.NodeNaming.extract_region_from_node_id/1)
      |> Enum.reject(&(&1 in ["unknown", ""]))
      |> Enum.uniq()
    else
      # Development: use full node IDs as distinct regions
      acks
      |> Enum.map(& &1.node_id)
      |> Enum.reject(&(&1 in ["unknown", ""]))
      |> Enum.uniq()
    end
  end

  def extract_from_acks(_), do: []

  @doc """
  Extract our local region from node configuration.
  In dev mode, returns the full node_id (e.g., "dev-node1") to match FlyMapEx custom regions.
  In production, extracts region prefix from node_id.
  """
  def extract_our_region do
    node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    if CorroPort.NodeConfig.production?() do
      region = CorroPort.NodeNaming.extract_region_from_node_id(node_id)
      if region in ["unknown", ""], do: "local", else: region
    else
      # Dev: use full node_id as region name (matches custom FlyMapEx regions)
      node_id
    end
  end
end

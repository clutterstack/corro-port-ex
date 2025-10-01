defmodule CorroPort.RegionExtractor do
  @moduledoc """
  Graceful region extraction that always returns a list, even on errors.
  Used by domain GenServers to compute regions from their data.
  """

  @doc """
  Extract regions from a list of node IDs.
  Always returns a list, empty on error.
  """
  def extract_from_nodes({:ok, nodes}) when is_list(nodes) do
    nodes
    |> Enum.map(&CorroCLI.Parser.extract_region_from_node_id/1)
    |> Enum.reject(&(&1 in ["unknown", ""]))
    |> Enum.uniq()
  end

  def extract_from_nodes({:error, _reason}), do: []
  def extract_from_nodes(nil), do: []

  @doc """
  Extract regions from a list of cluster members.
  Always returns a list, empty on error.
  """
  def extract_from_members({:ok, members}) when is_list(members) do
    case CorroPort.NodeConfig.production?() do
      true ->
        # Production: extract from member data
        members
        |> Enum.map(&CorroPort.AckTracker.member_to_node_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&CorroCLI.Parser.extract_region_from_node_id/1)
        |> Enum.reject(&(&1 in ["unknown", ""]))
        |> Enum.uniq()

      false ->
        # Development: if we have CLI members, they're all in "dev" region
        if length(members) > 0, do: ["dev"], else: []
    end
  end

  def extract_from_members({:error, _reason}), do: []
  def extract_from_members(nil), do: []

  @doc """
  Extract regions from acknowledgment data.
  Always returns a list, empty on error.
  """
  def extract_from_acks(acks) when is_list(acks) do
    acks
    |> Enum.map(& &1.node_id)
    |> Enum.map(&CorroCLI.Parser.extract_region_from_node_id/1)
    |> Enum.reject(&(&1 in ["unknown", ""]))
    |> Enum.uniq()
  end

  def extract_from_acks(_), do: []

  @doc """
  Extract our local region from node configuration.
  """
  def extract_our_region do
    node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    region = CorroCLI.Parser.extract_region_from_node_id(node_id)

    if region in ["unknown", ""], do: "local", else: region
  end
end

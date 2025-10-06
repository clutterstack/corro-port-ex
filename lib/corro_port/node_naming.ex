defmodule CorroPort.NodeNaming do
  @moduledoc """
  Shared helpers for working with Corrosion node identifiers.

  Production nodes are expected to use the pattern `region-machine_id`, where the
  region prefix comes from Fly.io (e.g., `ams-123abc`). Development nodes typically
  use identifiers like `dev-node1`, `dev-node2`, etc.
  """

  @type node_id :: String.t() | nil

  @doc """
  Extract the region prefix (characters before the first "-") from a node identifier.

  * `"ams-machine123"` -> `"ams"`
  * `"dev-node1"` -> `"dev"`

  Returns `"unknown"` when the identifier does not include a plausible region
  segment and `"invalid"` for non-string inputs.
  """
  @spec extract_region_from_node_id(node_id) :: String.t()
  def extract_region_from_node_id(node_id)

  def extract_region_from_node_id(node_id) when is_binary(node_id) do
    case String.split(node_id, "-", parts: 2) do
      [region, _machine_id] when byte_size(region) >= 2 and byte_size(region) <= 4 ->
        region

      _ ->
        "unknown"
    end
  end

  def extract_region_from_node_id(_), do: "invalid"

  @doc """
  Convert a list of cluster member maps into a map of node_id -> region.
  Members without an `"id"` field are ignored.
  """
  @spec regions_by_member_id(list(map())) :: map()
  def regions_by_member_id(members) when is_list(members) do
    members
    |> Enum.map(fn member ->
      member_id = Map.get(member, "id", "unknown")
      region = extract_region_from_node_id(member_id)
      {member_id, region}
    end)
    |> Enum.reject(fn {member_id, _region} -> member_id == "unknown" end)
    |> Enum.into(%{})
  end

  def regions_by_member_id(_), do: %{}
end

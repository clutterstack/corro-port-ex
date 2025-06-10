defmodule CorroPort.ClusterAPI do
  @moduledoc """
  API for querying Corrosion cluster state and system information.

  This module provides functions for inspecting cluster membership,
  tracked peers, system tables, and node information.

  Uses `CorroPort.CorrosionClient` for the underlying HTTP transport.
  """
  require Logger

  alias CorroPort.CorrosionClient

  ## Cluster Management

  @doc """
  Gets cluster member information by querying the __corro_members table.

  ## Parameters
  - `port`: API port (optional)

  ## Returns
  - `{:ok, members}` where members is a list of parsed member maps
  - `{:error, reason}` on failure
  """
  def get_cluster_members(port \\ nil) do
    query = "SELECT * FROM __corro_members"

    case CorrosionClient.execute_query(query, port) do
      {:ok, response} ->
        members = CorrosionClient.parse_query_response(response)
        parsed_members = Enum.map(members, &parse_member_foca_state/1)
        {:ok, parsed_members}
      error ->
        error
    end
  end

  @doc """
  Gets comprehensive cluster information from Corrosion system tables.

  Queries the essential Corrosion system tables to build cluster state:
  - `__corro_members`: Cluster members and their status
  - `crsql_tracked_peers`: Tracked peers for replication

  ## Returns
  Map containing:
  - `members`: List of cluster members (if available)
  - `tracked_peers`: List of tracked peers (if available)
  - `member_count`: Number of cluster members
  - `peer_count`: Number of tracked peers
  """
  def get_cluster_info(port \\ nil) do
    # Start with basic structure
    cluster_data = %{
      "members" => [],
      "tracked_peers" => [],
      "member_count" => 0,
      "peer_count" => 0
    }

    # Get members and peers directly
    cluster_data
    |> fetch_members(port)
    |> fetch_tracked_peers(port)
    |> then(&{:ok, &1})
  end

  defp fetch_members(cluster_data, port) do
    case get_cluster_members(port) do
      {:ok, members} ->
        Map.merge(cluster_data, %{"members" => members, "member_count" => length(members)})
      {:error, _} ->
        Logger.debug("Could not fetch cluster members (table may not exist)")
        cluster_data
    end
  end

  defp fetch_tracked_peers(cluster_data, port) do
    case get_tracked_peers(port) do
      {:ok, peers} ->
        Map.merge(cluster_data, %{"tracked_peers" => peers, "peer_count" => length(peers)})
      {:error, _} ->
        Logger.debug("Could not fetch tracked peers (table may not exist)")
        cluster_data
    end
  end

  @doc """
  Gets tracked peers from the crsql_tracked_peers table.
  """
  def get_tracked_peers(port \\ nil) do
    query = "SELECT * FROM crsql_tracked_peers"

    case CorrosionClient.execute_query(query, port) do
      {:ok, response} ->
        {:ok, CorrosionClient.parse_query_response(response)}
      error ->
        error
    end
  end

  ## System Introspection

@doc """
  Gets local node information using the configured Elixir node ID.

  Returns the node identification from the application configuration
  instead of querying Corrosion database tables.
  """
  def get_info(_port \\ nil) do
    node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    {:ok, %{
      "node_id" => node_id
    }}
  end

  defp extract_node_id_from_site(site_id_result) do
    case site_id_result do
      [site_info | _] when is_map(site_info) ->
        # Get the actual site_id value (should be a UUID)
        site_info |> Map.values() |> List.first() || "unknown"
      _ ->
        "unknown"
    end
  end
  ## Data Parsing and Formatting

  @doc """
  Parses a member row from __corro_members table.

  Extracts human-readable information from the foca_state JSON column
  and adds parsed fields to the member data.
  """
  def parse_member_foca_state(member_row) do
    case Map.get(member_row, "foca_state") do
      foca_state when is_binary(foca_state) ->
        case Jason.decode(foca_state) do
          {:ok, parsed} ->
            member_row
            |> Map.put("parsed_foca_state", parsed)
            |> Map.put("member_id", get_in(parsed, ["id", "id"]))
            |> Map.put("member_addr", get_in(parsed, ["id", "addr"]))
            |> Map.put("member_ts", get_in(parsed, ["id", "ts"]))
            |> Map.put("member_cluster_id", get_in(parsed, ["id", "cluster_id"]))
            |> Map.put("member_incarnation", Map.get(parsed, "incarnation"))
            |> Map.put("member_state", Map.get(parsed, "state"))

          {:error, _} ->
            Map.put(member_row, "parse_error", "Invalid JSON in foca_state")
        end

      _ ->
        Map.put(member_row, "parse_error", "Missing or invalid foca_state")
    end
  end

  @doc """
  Formats a Corrosion timestamp (nanoseconds since epoch) to readable format.

  ## Examples
      iex> CorroPort.ClusterAPI.format_corrosion_timestamp(1640995200000000000)
      "2022-01-01 00:00:00 UTC"
  """
  def format_corrosion_timestamp(nil), do: "Unknown"
  def format_corrosion_timestamp(ts) when is_integer(ts) do
    seconds = div(ts, 1_000_000_000)

    case DateTime.from_unix(seconds) do
      {:ok, datetime} ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      {:error, _} ->
        "Invalid timestamp"
    end
  end
  def format_corrosion_timestamp(_), do: "Invalid timestamp"
end

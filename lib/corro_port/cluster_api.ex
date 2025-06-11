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
  - Local node status check

  ## Returns
  Map containing:
  - `members`: List of cluster members (if available)
  - `tracked_peers`: List of tracked peers (if available)
  - `member_count`: Number of remote cluster members
  - `active_member_count`: Number of active (non-Down) remote members
  - `peer_count`: Number of tracked peers
  - `local_node_active`: Boolean indicating if local node is responding
  - `total_active_nodes`: Total active nodes including local
  """
  def get_cluster_info(port \\ nil) do
    # Start with basic structure
    cluster_data = %{
      "members" => [],
      "tracked_peers" => [],
      "member_count" => 0,
      "active_member_count" => 0,
      "peer_count" => 0,
      "local_node_active" => false,
      "total_active_nodes" => 0
    }

    # Check if local node is active (can respond to API calls)
    local_active = check_local_node_active(port)

    # Get members and peers
    cluster_data
    |> Map.put("local_node_active", local_active)
    |> fetch_members_with_activity(port)
    |> fetch_tracked_peers(port)
    |> calculate_total_active_nodes()
    |> then(&{:ok, &1})
  end

  @doc """
  Checks if the local Corrosion node considers itself active.

  This does a simple connectivity test to the local API as a proxy
  for the node being up and responsive.
  """
  def check_local_node_active(port \\ nil) do
    case CorrosionClient.execute_query("SELECT 1 as alive", port) do
      {:ok, _} ->
        Logger.debug("Local Corrosion node is responding")
        true
      {:error, reason} ->
        Logger.debug("Local Corrosion node not responding: #{inspect(reason)}")
        false
    end
  end

  @doc """
  Gets the local node's membership status by finding it in __corro_members.

  Attempts to identify the local node by matching gossip addresses.
  """
  def get_local_member_status(port \\ nil) do
    case get_cluster_members(port) do
      {:ok, members} ->
        local_gossip_port = get_local_gossip_port()

        # Find member whose gossip address matches our local gossip port
        local_member = Enum.find(members, fn member ->
          case Map.get(member, "member_addr") do
            addr when is_binary(addr) ->
              case String.split(addr, ":") do
                [_ip, port_str] ->
                  case Integer.parse(port_str) do
                    {port, _} -> port == local_gossip_port
                    _ -> false
                  end
                _ -> false
              end
            _ -> false
          end
        end)

        case local_member do
          nil -> {:error, :not_found_in_members}
          member -> {:ok, member}
        end

      error -> error
    end
  end

  defp fetch_members_with_activity(cluster_data, port) do
    case get_cluster_members(port) do
      {:ok, members} ->
        # Count active members (not "Down" state)
        active_members = Enum.filter(members, fn member ->
          member_state = Map.get(member, "member_state", "Unknown")
          member_state != "Down"
        end)

        Logger.debug("Found #{length(members)} total members, #{length(active_members)} active")

        Map.merge(cluster_data, %{
          "members" => members,
          "member_count" => length(members),
          "active_member_count" => length(active_members)
        })
      {:error, reason} ->
        Logger.debug("Could not fetch cluster members: #{inspect(reason)}")
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

  defp calculate_total_active_nodes(cluster_data) do
    local_active = Map.get(cluster_data, "local_node_active", false)
    active_members = Map.get(cluster_data, "active_member_count", 0)

    total_active = if local_active, do: active_members + 1, else: active_members

    Map.put(cluster_data, "total_active_nodes", total_active)
  end

  defp get_local_gossip_port do
    config = Application.get_env(:corro_port, :node_config, %{
      corrosion_gossip_port: 8787
    })
    config[:corrosion_gossip_port] || 8787
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
  def get_info(port \\ nil) do
    node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    local_active = check_local_node_active(port)

    {:ok, %{
      "node_id" => node_id,
      "local_active" => local_active
    }}
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

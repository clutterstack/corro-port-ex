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
  Gets comprehensive cluster information from various internal tables.

  Queries multiple Corrosion system tables to build a complete picture
  of cluster state including members, tracked peers, and available tables.

  ## Returns
  Map containing:
  - `available_tables`: List of Corrosion system table names
  - `members`: List of cluster members (if available)
  - `tracked_peers`: List of tracked peers (if available)
  - `member_count`: Number of cluster members
  - `peer_count`: Number of tracked peers
  """
  def get_cluster_info(port \\ nil) do
    # Discover available Corrosion tables
    tables_query = """
    SELECT name FROM sqlite_master
    WHERE type='table' AND (name LIKE '__corro_%' OR name LIKE 'crsql_%')
    """

    case CorrosionClient.execute_query(tables_query, port) do
      {:ok, response} ->
        available_tables = CorrosionClient.parse_query_response(response)
        table_names = Enum.map(available_tables, & &1["name"])

        Logger.debug("Available Corrosion tables: #{inspect(table_names)}")

        cluster_data = %{
          "available_tables" => table_names,
          "members" => [],
          "tracked_peers" => [],
          "member_count" => 0,
          "peer_count" => 0
        }

        cluster_data
        |> maybe_add_members(table_names, port)
        |> maybe_add_tracked_peers(table_names, port)
        |> then(&{:ok, &1})

      error ->
        Logger.warning("Failed to get table list: #{inspect(error)}")
        error
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
  Gets local node information including site ID and available tables.

  Attempts to gather various pieces of information about the current node
  by querying system tables and extracting node identification.
  """
  def get_info(port \\ nil) do
    queries = [
      {"site_id", "SELECT * FROM crsql_site_id"},
      {"tables", "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '__corro_%' AND name NOT LIKE 'crsql_%'"},
      {"corro_state", "SELECT * FROM __corro_state LIMIT 5"}
    ]

    results = Enum.reduce(queries, %{}, fn {key, query}, acc ->
      case CorrosionClient.execute_query(query, port) do
        {:ok, response} ->
          parsed = CorrosionClient.parse_query_response(response)
          Map.put(acc, key, parsed)
        {:error, error} ->
          Logger.debug("Query failed for #{key}: #{error}")
          Map.put(acc, key, "Error: #{error}")
      end
    end)

    node_id = extract_node_id(results)
    {:ok, Map.put(results, "node_id", node_id)}
  end

  ## Private Helper Functions

  defp maybe_add_members(cluster_data, table_names, port) do
    if "__corro_members" in table_names do
      case get_cluster_members(port) do
        {:ok, members} ->
          Map.merge(cluster_data, %{"members" => members, "member_count" => length(members)})
        _ ->
          cluster_data
      end
    else
      cluster_data
    end
  end

  defp maybe_add_tracked_peers(cluster_data, table_names, port) do
    if "crsql_tracked_peers" in table_names do
      case get_tracked_peers(port) do
        {:ok, peers} ->
          Map.merge(cluster_data, %{"tracked_peers" => peers, "peer_count" => length(peers)})
        _ ->
          cluster_data
      end
    else
      cluster_data
    end
  end

  defp extract_node_id(results) do
    case Map.get(results, "site_id") do
      [site_info | _] when is_map(site_info) ->
        site_info |> Map.values() |> List.first() || "unknown"
      _ ->
        case Map.get(results, "corro_state") do
          [first_row | _] when is_map(first_row) ->
            first_row
            |> Map.get("node_id", Map.get(first_row, "id", Map.get(first_row, "site_id", "unknown")))
          _ -> "unknown"
        end
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

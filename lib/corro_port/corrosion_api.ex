defmodule CorroPort.CorrosionAPI do
  @moduledoc """
  Client for interacting with the Corrosion HTTP API.
  Corrosion uses /v1/queries for reads and /v1/transactions for writes.
  """
  require Logger

  @doc """
  Gets cluster member information by querying the __corro_members table.
  Returns {:ok, members} or {:error, reason}.
  """
  def get_cluster_members(port \\ nil) do
    port = port || get_api_port()
    query = "SELECT * FROM __corro_members"

    case execute_query(query, port) do
      {:ok, response} ->
        {:ok, parse_query_response(response)}
      error ->
        error
    end
  end

  @doc """
  Gets basic cluster information from various internal tables.
  """
  def get_cluster_info(port \\ nil) do
    port = port || get_api_port()

    # Try to get cluster information from multiple sources
    with {:ok, members} <- get_cluster_members(port),
         {:ok, peers} <- get_tracked_peers(port) do

      cluster_info = %{
        "members" => members,
        "tracked_peers" => peers,
        "member_count" => length(members),
        "peer_count" => length(peers)
      }

      {:ok, cluster_info}
    else
      error -> error
    end
  end

  @doc """
  Gets tracked peers from the crsql_tracked_peers table.
  """
  def get_tracked_peers(port \\ nil) do
    port = port || get_api_port()
    query = "SELECT * FROM crsql_tracked_peers"

    case execute_query(query, port) do
      {:ok, response} ->
        {:ok, parse_query_response(response)}
      error ->
        error
    end
  end

  @doc """
  Gets local node information.
  """
  def get_info(port \\ nil) do
    port = port || get_api_port()

    # Try to get some basic info about this node
    queries = [
      {"site_id", "SELECT crsql_siteid()"},
      {"db_version", "SELECT crsql_dbversion()"},
      {"tables", "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '__corro_%' AND name NOT LIKE 'crsql_%'"}
    ]

    info = %{}

    results = Enum.reduce(queries, %{}, fn {key, query}, acc ->
      case execute_query(query, port) do
        {:ok, response} ->
          parsed = parse_query_response(response)
          Map.put(acc, key, parsed)
        {:error, _} ->
          Map.put(acc, key, "Error")
      end
    end)

    # Extract site_id as node_id if available
    node_id = case Map.get(results, "site_id") do
      [%{"crsql_siteid()" => site_id}] -> site_id
      _ -> "unknown"
    end

    {:ok, Map.put(results, "node_id", node_id)}
  end

  @doc """
  Execute a SQL query against Corrosion's API.
  """
  def execute_query(query, port \\ nil) do
    port = port || get_api_port()
    base_url = "http://127.0.0.1:#{port}"

    Logger.debug("Executing query on port #{port}: #{query}")

    case Req.post("#{base_url}/v1/queries",
                  json: query,
                  headers: [{"content-type", "application/json"}],
                  receive_timeout: 5000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}
      {:ok, %{status: status, body: body}} ->
        Logger.warning("Query failed with status #{status}: #{inspect(body)}")
        {:error, "HTTP #{status}: #{inspect(body)}"}
      {:error, exception} ->
        Logger.warning("Failed to connect to Corrosion API on port #{port}: #{inspect(exception)}")
        {:error, "Connection failed: #{inspect(exception)}"}
    end
  end

  @doc """
  Parse Corrosion's query response format into a list of maps.
  """
  def parse_query_response(response) when is_binary(response) do
    # Corrosion returns JSONL (one JSON object per line)
    lines = String.split(response, "\n")

    {columns, rows} = Enum.reduce(lines, {nil, []}, fn line, {cols, rows_acc} ->
      case String.trim(line) do
        "" -> {cols, rows_acc}
        json_line ->
          case Jason.decode(json_line) do
            {:ok, %{"columns" => columns}} ->
              {columns, rows_acc}
            {:ok, %{"row" => [_row_num, values]}} when not is_nil(cols) ->
              row_map = Enum.zip(cols, values) |> Enum.into(%{})
              {cols, [row_map | rows_acc]}
            {:ok, %{"eoq" => _}} ->
              {cols, rows_acc}
            _ ->
              {cols, rows_acc}
          end
      end
    end)

    Enum.reverse(rows)
  end

  def parse_query_response(response) when is_list(response) do
    # Already parsed
    response
  end

  def parse_query_response(_), do: []

  @doc """
  Determines the Corrosion API port based on the Phoenix port.
  For development, defaults to 8081 as per config-local.toml.
  """
  def get_api_port() do
    # For now, let's use the port from config-local.toml
    # TODO: Make this configurable per node for multi-node setups
    8081
  end

  @doc """
  Try to detect the correct API port by testing common ports.
  """
  def detect_api_port() do
    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000

    # Common port patterns to try
    candidate_ports = [
      8081,  # Default from config
      8082,  # Second node
      8083,  # Third node
    ]

    Logger.debug("Phoenix running on port #{phoenix_port}, trying Corrosion API ports: #{inspect(candidate_ports)}")

    Enum.find(candidate_ports, fn port ->
      case execute_query("SELECT 1", port) do
        {:ok, _} ->
          Logger.info("Found working Corrosion API on port #{port}")
          true
        _ ->
          false
      end
    end) || 8081  # Fallback to default
  end
end

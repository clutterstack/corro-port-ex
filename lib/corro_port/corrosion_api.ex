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
        members = parse_query_response(response)
        parsed_members = Enum.map(members, &parse_member_foca_state/1)
        {:ok, parsed_members}
      error ->
        error
    end
  end

  @doc """
  Gets basic cluster information from various internal tables.
  """
  def get_cluster_info(port \\ nil) do
    port = port || get_api_port()

    # Get all available corrosion tables first
    tables_query = "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '__corro_%' OR name LIKE 'crsql_%')"

    case execute_query(tables_query, port) do
      {:ok, response} ->
        available_tables = parse_query_response(response)
        table_names = Enum.map(available_tables, & &1["name"])

        Logger.debug("Available Corrosion tables: #{inspect(table_names)}")

        # Try to get data from available tables
        cluster_data = %{
          "available_tables" => table_names,
          "members" => [],
          "tracked_peers" => [],
          "member_count" => 0,
          "peer_count" => 0
        }

        # Try to get members if table exists
        cluster_data = if "__corro_members" in table_names do
          case get_cluster_members(port) do
            {:ok, members} ->
              Map.merge(cluster_data, %{"members" => members, "member_count" => length(members)})
            _ ->
              cluster_data
          end
        else
          cluster_data
        end

        # Try to get tracked peers if table exists
        cluster_data = if "crsql_tracked_peers" in table_names do
          case get_tracked_peers(port) do
            {:ok, peers} ->
              Map.merge(cluster_data, %{"tracked_peers" => peers, "peer_count" => length(peers)})
            _ ->
              cluster_data
          end
        else
          cluster_data
        end

        {:ok, cluster_data}

      error ->
        Logger.warning("Failed to get table list: #{inspect(error)}")
        error
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
  Gets messages from the node_messages table, ordered by timestamp.
  """
  def get_node_messages(port \\ nil) do
    port = port || get_api_port()
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"

    case execute_query(query, port) do
      {:ok, response} ->
        {:ok, parse_query_response(response)}
      error ->
        error
    end
  end

  @doc """
  Gets the latest message for each node from the node_messages table.
  """
  def get_latest_node_messages(port \\ nil) do
    port = port || get_api_port()

    # Get the latest message per node_id
    query = """
    SELECT node_id, message, timestamp, sequence
    FROM node_messages
    WHERE (node_id, timestamp) IN (
      SELECT node_id, MAX(timestamp)
      FROM node_messages
      GROUP BY node_id
    )
    ORDER BY timestamp DESC
    """

    case execute_query(query, port) do
      {:ok, response} ->
        {:ok, parse_query_response(response)}
      error ->
        error
    end
  end

  @doc """
  Inserts a new message into the node_messages table.
  """
  def insert_message(node_id, message, port \\ nil) do
    port = port || get_api_port()

    # Generate a sequence number based on current time (simple approach)
    sequence = System.system_time(:millisecond)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # Create the transaction as an array of SQL statements (as expected by Corrosion)
    transactions = [
      "INSERT INTO node_messages (pk, node_id, message, sequence, timestamp) VALUES (\"#{node_id}_#{sequence}\", \"#{node_id}\", \"#{message}\", #{sequence}, \"#{timestamp}\")"
    ]

    case execute_transaction(transactions, port) do
      {:ok, _response} ->
        {:ok, %{node_id: node_id, message: message, sequence: sequence, timestamp: timestamp}}
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
      {"site_id", "SELECT * FROM crsql_site_id"},
      {"tables", "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '__corro_%' AND name NOT LIKE 'crsql_%'"},
      {"corro_state", "SELECT * FROM __corro_state LIMIT 5"}
    ]

    results = Enum.reduce(queries, %{}, fn {key, query}, acc ->
      case execute_query(query, port) do
        {:ok, response} ->
          parsed = parse_query_response(response)
          Map.put(acc, key, parsed)
        {:error, error} ->
          Logger.debug("Query failed for #{key}: #{error}")
          Map.put(acc, key, "Error: #{error}")
      end
    end)

    # Use the Phoenix node configuration instead of trying to extract from Corrosion
    node_id = CorroPort.NodeConfig.get_corrosion_node_id()

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
  Execute a SQL transaction against Corrosion's API.
  """
  def execute_transaction(transactions, port \\ nil) do
    port = port || get_api_port()
    base_url = "http://127.0.0.1:#{port}"

    Logger.debug("Executing transaction on port #{port}: #{inspect(transactions)}")

    case Req.post("#{base_url}/v1/transactions",
                  json: transactions,
                  headers: [{"content-type", "application/json"}],
                  receive_timeout: 5000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}
      {:ok, %{status: status, body: body}} ->
        Logger.warning("Transaction failed with status #{status}: #{inspect(body)}")
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
  Parses a member row from __corro_members table, extracting human-readable
  information from the foca_state JSON column.
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
            member_row
            |> Map.put("parse_error", "Invalid JSON in foca_state")
        end

      _ ->
        member_row
        |> Map.put("parse_error", "Missing or invalid foca_state")
    end
  end

  @doc """
  Formats a timestamp from Corrosion (nanoseconds since epoch) to a readable format.
  """
  def format_corrosion_timestamp(nil), do: "Unknown"
  def format_corrosion_timestamp(ts) when is_integer(ts) do
    # Convert nanoseconds to seconds
    seconds = div(ts, 1_000_000_000)

    case DateTime.from_unix(seconds) do
      {:ok, datetime} ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      {:error, _} ->
        "Invalid timestamp"
    end
  end
  def format_corrosion_timestamp(_), do: "Invalid timestamp"

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

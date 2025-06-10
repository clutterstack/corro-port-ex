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

  # Try selecting columns in a different order to see if that fixes the alignment
  query = """
  SELECT message, node_id, timestamp, sequence
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
    parsed = parse_query_response(response)

    # Map the columns back to the expected structure
    mapped = Enum.map(parsed, fn row ->
      # If the columns are coming back as positional, we need to map them correctly
      case row do
        # If it's a map with string keys (which it should be)
        %{"message" => msg, "node_id" => nid, "timestamp" => ts, "sequence" => seq} ->
          %{"node_id" => nid, "message" => msg, "timestamp" => ts, "sequence" => seq}

        # If for some reason the keys are wrong, try to fix based on the pattern you showed
        %{"node_id" => actual_message, "message" => actual_node_port, "timestamp" => ts, "sequence" => seq}
        when is_binary(actual_message) ->
          if String.contains?(actual_message, "Hello from") do
            # Extract the real node_id from the message
            node_id = case Regex.run(~r/Hello from (node\d+)/, actual_message) do
              [_, node_id] -> node_id
              _ -> "unknown"
            end

            %{
              "node_id" => node_id,
              "message" => actual_message,
              "timestamp" => ts,
              "sequence" => seq
            }
          else
            # If it doesn't contain "Hello from", return as-is
            row
          end

        # Fallback - return as-is
        other -> other
      end
    end)

    {:ok, mapped}
  error ->
    error
end
end
def get_all_node_messages_debug(port \\ nil) do
  port = port || get_api_port()

  # Simple query to see raw data
  query = "SELECT * FROM node_messages ORDER BY timestamp DESC LIMIT 5"

  case execute_query(query, port) do
    {:ok, response} ->
      Logger.debug("=== RAW NODE_MESSAGES DEBUG ===")
      Logger.debug("Raw response: #{inspect(response)}")
      parsed = parse_query_response(response)
      Logger.debug("Parsed response: #{inspect(parsed)}")
      Logger.debug("=== END DEBUG ===")
      {:ok, parsed}
    error ->
      error
  end
end
  @doc """
  Inserts a new message into the node_messages table.
  Updated to match the call signature expected by ClusterLive.
  """
def insert_message(node_id, message, port \\ nil) do
  port = port || get_api_port()

  # Generate a sequence number based on current time
  sequence = System.system_time(:millisecond)
  timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

  # Use single quotes to avoid issues with double quotes in messages
  sql = """
  INSERT INTO node_messages (pk, node_id, message, sequence, timestamp)
  VALUES ('#{node_id}_#{sequence}', '#{node_id}', '#{message}', #{sequence}, '#{timestamp}')
  """

  Logger.debug("Inserting: node_id=#{node_id}, message=#{message}, port=#{port}")

  case execute_transaction([sql], port) do
    {:ok, _response} ->
      {:ok, %{node_id: node_id, message: message, sequence: sequence, timestamp: timestamp}}
    error ->
      error
  end
end

# Add a cleanup function to remove bad data
def cleanup_bad_messages(port \\ nil) do
  port = port || get_api_port()

  # Delete messages where the message field contains port numbers
  cleanup_sql = """
  DELETE FROM node_messages
  WHERE message IN ('8081', '8082', '8083', '8084', '8085')
  """

  case execute_transaction([cleanup_sql], port) do
    {:ok, _} ->
      Logger.info("Cleaned up malformed messages")
      {:ok, :cleaned}
    error ->
      Logger.warning("Failed to cleanup messages: #{inspect(error)}")
      error
  end
end

# Add a function to test the insert with known good data
def test_insert(port \\ nil) do
  node_id = CorroPort.NodeConfig.get_corrosion_node_id()
  test_message = "Test message from #{node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

  insert_message(node_id, test_message, port)
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

    # Try to extract node ID from various sources
    node_id = case Map.get(results, "site_id") do
      [site_info | _] when is_map(site_info) ->
        # crsql_site_id table might have different column names
        site_info |> Map.values() |> List.first() || "unknown"
      _ ->
        # Try getting from __corro_state table
        case Map.get(results, "corro_state") do
          [first_row | _] when is_map(first_row) ->
            # Look for common node ID field names
            first_row
            |> Map.get("node_id", Map.get(first_row, "id", Map.get(first_row, "site_id", "unknown")))
          _ -> "unknown"
        end
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
  Gets the Corrosion API port for the current node from configuration.
  """
  def get_api_port() do
    config = Application.get_env(:corro_port, :node_config, [])
    Keyword.get(config, :corrosion_api_port, 8081)
  end

  @doc """
  Try to detect the correct API port by testing common ports.
  This is used as a fallback when the main API port isn't working.
  """
  def detect_api_port() do
    # First try the configured port
    configured_port = get_api_port()

    case execute_query("SELECT 1", configured_port) do
      {:ok, _} ->
        Logger.debug("Using configured Corrosion API port #{configured_port}")
        configured_port

      _ ->
        Logger.debug("Configured port #{configured_port} not working, trying alternatives...")

        # Fallback to common ports
        candidate_ports = [8081, 8082, 8083, 8084, 8085]

        Enum.find(candidate_ports, fn port ->
          case execute_query("SELECT 1", port) do
            {:ok, _} ->
              Logger.info("Found working Corrosion API on port #{port}")
              true
            _ ->
              false
          end
        end) || configured_port  # Fallback to configured port
    end
  end
end

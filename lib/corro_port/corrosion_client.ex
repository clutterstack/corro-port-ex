defmodule CorroPort.CorrosionClient do
  @moduledoc """
  Low-level HTTP client for interacting with the Corrosion database API.

  This module provides the basic HTTP transport layer for communicating
  with Corrosion's REST API endpoints:
  - `/queries` for read operations
  - `/transactions` for write operations

  For higher-level database operations, see `CorroPort.CorrosionAPI`.
  """
  require Logger

  @doc """
  Execute a SQL query against Corrosion's query endpoint.

  ## Parameters
  - `query`: SQL query string
  - `port`: API port (optional, defaults to configured port)

  ## Returns
  - `{:ok, response_body}` on success
  - `{:error, reason}` on failure

  ## Examples
      iex> CorroPort.CorrosionClient.execute_query("SELECT 1", 8081)
      {:ok, response_body}
  """
  def execute_query(query, port \\ nil) do
    # TODO: set base_url using application environment vars, for both local and prod
    port = port || get_corro_api_port()
    base_url = "http://127.0.0.1:#{port}"

    # Logger.debug("Executing query on port #{port}: #{query}")

    case Req.post("#{base_url}/v1/queries",
           json: query,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Query failed with status #{status}: #{inspect(body)}")
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, exception} ->
        Logger.warning(
          "Failed to connect to Corrosion API on port #{port}: #{inspect(exception)}"
        )

        {:error, "Connection failed: #{inspect(exception)}"}
    end
  end

  @doc """
  Execute a SQL transaction against Corrosion's transaction endpoint.

  ## Parameters
  - `transactions`: List of SQL statements to execute as a transaction
  - `port`: API port (optional, defaults to configured port)

  ## Returns
  - `{:ok, response_body}` on success
  - `{:error, reason}` on failure

  ## Examples
      iex> CorroPort.CorrosionClient.execute_transaction(["INSERT INTO users (name) VALUES ('Alice')"], 8081)
      {:ok, response_body}
  """
  def execute_transaction(transactions, port \\ nil) do
    port = port || get_corro_api_port()
    base_url = "http://127.0.0.1:#{port}"

    Logger.debug("Executing transaction on port #{port}: #{inspect(transactions)}")

    case Req.post("#{base_url}/v1/transactions",
           json: transactions,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Transaction failed with status #{status}: #{inspect(body)}")
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, exception} ->
        Logger.warning(
          "Failed to connect to Corrosion API on port #{port}: #{inspect(exception)}"
        )

        {:error, "Connection failed: #{inspect(exception)}"}
    end
  end

  @doc """
  Parse Corrosion's JSONL query response format into a list of maps.

  Corrosion returns responses in JSONL format (one JSON object per line):
  - `{"columns": ["col1", "col2", ...]}` - column definitions
  - `{"row": [row_number, [value1, value2, ...]]}` - data rows
  - `{"eoq": true}` - end of query marker

  ## Parameters
  - `response`: Raw response body from Corrosion API

  ## Returns
  List of maps where each map represents a row with column names as keys

  ## Examples
      iex> response = ~s({"columns": ["id", "name"]}\\n{"row": [1, [1, "Alice"]]}\\n{"eoq": true})
      iex> CorroPort.CorrosionClient.parse_query_response(response)
      [%{"id" => 1, "name" => "Alice"}]
  """
  def parse_query_response(response) when is_binary(response) do
    lines = String.split(response, "\n")

    {_columns, rows} =
      Enum.reduce(lines, {nil, []}, fn line, {cols, rows_acc} ->
        case String.trim(line) do
          "" ->
            {cols, rows_acc}

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
  Get the configured Corrosion API port for the current node.

  Reads from application config under `:corro_port, :node_config`.
  Falls back to port 8081 if not configured.
  """
  def get_corro_api_port do
    Application.get_env(:corro_port, :node_config)[:corrosion_api_port]
  end

  @doc """
  Test connectivity to a Corrosion API port.

  ## Parameters
  - `port`: Port to test (optional, defaults to configured port)

  ## Returns
  - `:ok` if connection successful
  - `{:error, reason}` if connection failed
  """
  def test_connection(port \\ nil) do
    case execute_query("SELECT 1", port) do
      {:ok, message} ->
        Logger.info(message)
        :ok

      error ->
        error
    end
  end
end

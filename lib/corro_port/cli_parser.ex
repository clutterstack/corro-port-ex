defmodule CorroPort.CorrosionParser do
  @moduledoc """
  Parses output from various Corrosion CLI commands.

  Handles the NDJSON (newline-delimited JSON) format that Corrosion uses
  for structured output from commands like `cluster members`, `cluster info`, etc.
  """

  require Logger

  @doc """
  Parses cluster members NDJSON output into a structured format.

  ## Parameters
  - `ndjson_output` - Raw NDJSON string output from `corrosion cluster members`

  ## Returns
  - `{:ok, members}` - List of parsed member maps with enhanced fields
  - `{:error, reason}` - Parse error details

  ## Examples
      iex> output = ~s({"id":"abc123","state":{"addr":"127.0.0.1:8787"}}\n{"id":"def456","state":{"addr":"127.0.0.1:8788"}})
      iex> CorroPort.CorrosionParser.parse_cluster_members(output)
      {:ok, [%{"id" => "abc123", "parsed_addr" => "127.0.0.1:8787", ...}, ...]}
  """
  def parse_cluster_members(ndjson_output) when is_binary(ndjson_output) do
    parse_ndjson(ndjson_output, &enhance_member/1)
  end

  @doc """
  Parses cluster info NDJSON output.

  ## Parameters
  - `ndjson_output` - Raw NDJSON string output from `corrosion cluster info`

  ## Returns
  - `{:ok, info}` - Parsed cluster info
  - `{:error, reason}` - Parse error details
  """
  def parse_cluster_info(ndjson_output) when is_binary(ndjson_output) do
    parse_ndjson(ndjson_output, &enhance_cluster_info/1)
  end

  @doc """
  Parses cluster status NDJSON output.
  """
  def parse_cluster_status(ndjson_output) when is_binary(ndjson_output) do
    parse_ndjson(ndjson_output, &enhance_status/1)
  end

  @doc """
  Generic NDJSON parser that can handle any corrosion command output.

  ## Parameters
  - `ndjson_output` - Raw NDJSON string
  - `enhancer_fun` - Optional function to enhance each parsed object

  ## Returns
  - `{:ok, objects}` - List of parsed JSON objects
  - `{:error, reason}` - Parse error details
  """
  def parse_ndjson(ndjson_output, enhancer_fun \\ &Function.identity/1) when is_binary(ndjson_output) do
    try do
      lines = String.split(ndjson_output, "\n", trim: true)

      {parsed_objects, errors} =
        lines
        |> Enum.map(&parse_json_line/1)
        |> Enum.split_with(&match?({:ok, _}, &1))

      # Extract successful results and apply enhancer
      objects =
        parsed_objects
        |> Enum.map(fn {:ok, obj} -> obj end)
        |> Enum.map(enhancer_fun)

      # Log any parse errors but don't fail the whole operation
      if length(errors) > 0 do
        Logger.warning("CorrosionParser: #{length(errors)} lines failed to parse: #{inspect(errors)}")
      end

      # Logger.debug("CorrosionParser: Successfully parsed #{length(objects)} objects")
      {:ok, objects}

    rescue
      error ->
        Logger.error("CorrosionParser: Error parsing NDJSON: #{inspect(error)}")
        {:error, {:parse_error, error}}
    end
  end

  # Private functions

  defp parse_json_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, object} -> {:ok, object}
      {:error, reason} -> {:error, {line, reason}}
    end
  end

  # Enhancer functions for different command types

  defp enhance_member(member) when is_map(member) do
    member
    |> add_parsed_address()
    |> add_member_status()
    |> add_short_id()
  end

  defp enhance_cluster_info(info) when is_map(info) do
    info
    |> add_formatted_timestamps()
  end

  defp enhance_status(status) when is_map(status) do
    status
    |> add_formatted_timestamps()
    |> add_health_indicators()
  end

  # Enhancement helper functions

  defp add_parsed_address(member) do
    addr = get_in(member, ["state", "addr"]) || "unknown"
    Map.put(member, "parsed_addr", addr)
  end

  defp add_member_status(member) do
    # Determine status based on available data
    status = cond do
      get_in(member, ["state", "last_sync_ts"]) != nil -> "active"
      get_in(member, ["state", "ts"]) != nil -> "connected"
      get_in(member, ["state", "addr"]) != nil -> "reachable"
      true -> "unknown"
    end

    Map.put(member, "computed_status", status)
  end

  defp add_short_id(member) do
    case Map.get(member, "id") do
      id when is_binary(id) and byte_size(id) > 8 ->
        Map.put(member, "short_id", String.slice(id, 0, 8) <> "...")
      id ->
        Map.put(member, "short_id", id || "unknown")
    end
  end

  defp add_formatted_timestamps(object) when is_map(object) do
    # Find all timestamp fields and add formatted versions
    timestamp_fields = ["ts", "last_sync_ts", "created_at", "updated_at"]

    Enum.reduce(timestamp_fields, object, fn field, acc ->
      case get_in(acc, String.split(field, ".")) do
        ts when is_integer(ts) ->
          formatted_field = "formatted_#{field}"
          Map.put(acc, formatted_field, format_corrosion_timestamp(ts))
        _ ->
          acc
      end
    end)
  end

  defp add_health_indicators(status) when is_map(status) do
    # Add computed health indicators based on status data
    # This would depend on what fields are available in cluster status output
    Map.put(status, "overall_health", compute_health(status))
  end

  defp compute_health(status) do
    # Placeholder health computation
    # You'd customize this based on actual corrosion status output
    cond do
      Map.get(status, "error") -> "unhealthy"
      Map.get(status, "warning") -> "degraded"
      true -> "healthy"
    end
  end

  defp format_corrosion_timestamp(ts) when is_integer(ts) do
    # Corrosion timestamps are often in nanoseconds
    seconds = div(ts, 1_000_000_000)
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "invalid timestamp"
    end
  end

  defp format_corrosion_timestamp(_), do: "unknown"
end

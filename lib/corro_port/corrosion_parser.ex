defmodule CorroPort.CorrosionParser do
  @moduledoc """
  Parses output from various Corrosion CLI commands.

  Handles the NDJSON (newline-delimited JSON) format that Corrosion uses
  for structured output from commands like `cluster members`, `cluster info`, etc.

  Also properly handles single-node setups where CLI commands return empty results.
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

      # Single node case
      iex> CorroPort.CorrosionParser.parse_cluster_members("")
      {:ok, []}
  """
  def parse_cluster_members(ndjson_output) when is_binary(ndjson_output) do
    parse_ndjson(ndjson_output, &enhance_member/1)
  end

  # Handle nil input (can happen with some CLI error cases)
  def parse_cluster_members(nil) do
    Logger.debug("CorrosionParser: Received nil input for cluster members")
    {:ok, []}
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

  def parse_cluster_info(nil) do
    Logger.debug("CorrosionParser: Received nil input for cluster info")
    {:ok, []}
  end

  @doc """
  Parses cluster status NDJSON output.
  """
  def parse_cluster_status(ndjson_output) when is_binary(ndjson_output) do
    parse_ndjson(ndjson_output, &enhance_status/1)
  end

  def parse_cluster_status(nil) do
    Logger.debug("CorrosionParser: Received nil input for cluster status")
    {:ok, []}
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
  def parse_ndjson(ndjson_output, enhancer_fun \\ &Function.identity/1)

  # Handle nil input
  def parse_ndjson(nil, _enhancer_fun) do
    Logger.debug("CorrosionParser: Received nil input for NDJSON parsing")
    {:ok, []}
  end

  # Handle empty string (single node case)
  def parse_ndjson("", _enhancer_fun) do
    Logger.debug("CorrosionParser: Received empty string - likely single node setup")
    {:ok, []}
  end

  # Handle whitespace-only strings
  def parse_ndjson(ndjson_output, enhancer_fun) when is_binary(ndjson_output) do
    trimmed = String.trim(ndjson_output)

    if trimmed == "" do
      Logger.debug("CorrosionParser: Received whitespace-only string - likely single node setup")
      {:ok, []}
    else
      parse_non_empty_ndjson(trimmed, enhancer_fun)
    end
  end

  # The actual parsing logic, extracted for clarity
  defp parse_non_empty_ndjson(ndjson_output, enhancer_fun) do
    try do
      # Handle Corrosion's specific output format: concatenated pretty-printed JSON objects
      case parse_concatenated_json(ndjson_output, enhancer_fun) do
        {:ok, objects} when objects != [] ->
          {:ok, objects}

        {:ok, []} ->
          # Empty result, try other formats
          try_alternative_formats(ndjson_output, enhancer_fun)

        {:error, _} ->
          # Failed to parse as concatenated JSON, try other formats
          try_alternative_formats(ndjson_output, enhancer_fun)
      end
    rescue
      error ->
        Logger.error("CorrosionParser: Error parsing JSON/NDJSON: #{inspect(error)}")
        {:error, {:parse_error, error}}
    end
  end

  # Try to parse concatenated pretty-printed JSON objects (Corrosion's actual format)
  defp parse_concatenated_json(output, enhancer_fun) do
    # Split on "}\n{" pattern which separates concatenated JSON objects
    # Then reconstruct each complete JSON object
    parts = String.split(output, ~r/\}\s*\n\s*\{/)

    case length(parts) do
      1 ->
        # Single object, try to parse directly
        case Jason.decode(String.trim(output)) do
          {:ok, object} when is_map(object) ->
            {:ok, [enhancer_fun.(object)]}

          {:ok, array} when is_list(array) ->
            {:ok, Enum.map(array, enhancer_fun)}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        # Multiple objects, reconstruct and parse each
        objects =
          parts
          |> Enum.with_index()
          |> Enum.map(fn {part, index} ->
            # Add back the braces that were removed by splitting
            complete_json =
              cond do
                # First part: add closing brace
                index == 0 -> part <> "}"
                # Last part: add opening brace
                index == length(parts) - 1 -> "{" <> part
                # Middle parts: add both braces
                true -> "{" <> part <> "}"
              end

            case Jason.decode(String.trim(complete_json)) do
              {:ok, object} when is_map(object) -> {:ok, enhancer_fun.(object)}
              {:error, reason} -> {:error, {complete_json, reason}}
            end
          end)

        # Separate successful parses from errors
        {successes, errors} = Enum.split_with(objects, &match?({:ok, _}, &1))

        if errors != [] do
          Logger.warning(
            "CorrosionParser: #{length(errors)} objects failed to parse: #{inspect(errors)}"
          )
        end

        parsed_objects = Enum.map(successes, fn {:ok, obj} -> obj end)
        {:ok, parsed_objects}
    end
  end

  # Fallback to try other formats
  defp try_alternative_formats(ndjson_output, enhancer_fun) do
    # Try NDJSON format (one JSON object per line)
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
    if errors != [] do
      Logger.warning(
        "CorrosionParser: #{length(errors)} lines failed to parse: #{inspect(errors)}"
      )
    end

    Logger.debug(
      "CorrosionParser: Successfully parsed #{length(objects)} objects via NDJSON fallback"
    )

    {:ok, objects}
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
    |> add_display_fields()
    |> add_status_badge_class()
  end

  defp enhance_cluster_info(info) when is_map(info) do
    # For cluster info, we might not need much enhancement yet
    # Add basic timestamp formatting if needed
    add_basic_timestamps(info)
  end

  defp enhance_status(status) when is_map(status) do
    status
    |> add_basic_timestamps()
    |> add_health_indicators()
  end

  # Streamlined enhancement - only compute what we actually display
defp add_display_fields(member) do
  state = Map.get(member, "state", %{})

  # Handle rtts being null/nil in the JSON
  rtts = Map.get(member, "rtts") || []

  # Compute only the fields we actually use in the template
  short_id =
    case Map.get(member, "id") do
      id when is_binary(id) and byte_size(id) > 8 -> String.slice(id, 0, 8) <> "..."
      id -> id || "unknown"
    end

  parsed_addr = Map.get(state, "addr", "unknown")

  # Status computation
  computed_status =
    cond do
      Map.get(state, "last_sync_ts") != nil -> "active"
      Map.get(state, "ts") != nil -> "connected"
      parsed_addr != "unknown" -> "reachable"
      true -> "unknown"
    end

  # RTT stats (only avg and count since that's what we display)
  # Ensure rtts is a list before filtering
  numeric_rtts =
    if is_list(rtts) do
      Enum.filter(rtts, &is_number/1)
    else
      []
    end

  rtt_avg =
    if numeric_rtts != [] do
      Float.round(Enum.sum(numeric_rtts) / length(numeric_rtts), 1)
    else
      0.0
    end

  # Formatted timestamp
  formatted_last_sync =
    case Map.get(state, "last_sync_ts") do
      ts when is_integer(ts) ->
        format_corrosion_timestamp(ts)
    end

  # Add all computed display fields
  member
  |> Map.put("display_id", short_id)
  |> Map.put("display_addr", parsed_addr)
  |> Map.put("display_status", computed_status)
  |> Map.put("display_cluster_id", Map.get(state, "cluster_id", "?"))
  |> Map.put("display_ring", Map.get(state, "ring", "?"))
  |> Map.put("display_rtt_avg", rtt_avg)
  |> Map.put("display_rtt_count", length(numeric_rtts))
  |> Map.put("display_last_sync", formatted_last_sync)
end

  defp add_status_badge_class(member) do
    status = Map.get(member, "display_status")

    badge_class =
      case status do
        "active" -> "badge badge-sm badge-success"
        "connected" -> "badge badge-sm badge-info"
        "reachable" -> "badge badge-sm badge-warning"
        _ -> "badge badge-sm badge-neutral"
      end

    Map.put(member, "display_status_class", badge_class)
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

  # Simple timestamp formatting for non-member objects
  defp add_basic_timestamps(object) when is_map(object) do
    # Add formatted timestamps for common fields if they exist
    timestamp_fields = ["ts", "created_at", "updated_at"]

    Enum.reduce(timestamp_fields, object, fn field, acc ->
      case Map.get(acc, field) do
        ts when is_integer(ts) ->
          formatted_field = "formatted_#{field}"
          Map.put(acc, formatted_field, format_corrosion_timestamp(ts))

        _ ->
          acc
      end
    end)
  end

  # defp format_corrosion_timestamp(ts) when is_integer(ts) do
  #   # Corrosion timestamps are often in nanoseconds
  #   seconds = div(ts, 1_000_000_000)

  #   case DateTime.from_unix(seconds) do
  #     {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  #     _ -> "invalid timestamp"
  #   end
  # end

  # defp format_corrosion_timestamp(_), do: "unknown"


  @doc """
Formats a Corrosion timestamp (uhlc NTP64 format) to readable format.

Corrosion uses the uhlc library's NTP64 format, which is:
- 64-bit fixed-point number
- Upper 32 bits: seconds since Unix epoch (January 1, 1970)
- Lower 32 bits: fractional seconds (1 unit = 1/2^32 seconds)

Note: Despite the "NTP64" name, uhlc uses Unix epoch, not NTP epoch.

## Examples
    iex> CorroPort.ClusterAPI.format_corrosion_timestamp(7517054269677675168)
    "2025-06-17 22:49:43 UTC"
"""
def format_corrosion_timestamp(nil), do: "Never"

def format_corrosion_timestamp(ntp64_timestamp) when is_integer(ntp64_timestamp) do
  import Bitwise

  # uhlc's NTP64 is a 64-bit fixed-point number:
  # Upper 32 bits: seconds since Unix epoch (Jan 1, 1970)
  # Lower 32 bits: fractional seconds

  # Extract the seconds part (upper 32 bits)
  unix_seconds = ntp64_timestamp >>> 32

  # Extract the fractional part (lower 32 bits)
  ntp_fraction = ntp64_timestamp &&& 0xFFFFFFFF

  # Convert fractional part to microseconds for DateTime
  # ntp_fraction * 1_000_000 / 2^32
  microseconds = div(ntp_fraction * 1_000_000, 4_294_967_296)

  case DateTime.from_unix(unix_seconds, :second) do
    {:ok, datetime} ->
      # Add microseconds for sub-second precision
      datetime_with_precision = %{datetime | microsecond: {microseconds, 6}}
      Calendar.strftime(datetime_with_precision, "%Y-%m-%d %H:%M:%S UTC") |> dbg

    {:error, _} ->
      "Invalid timestamp"
  end
end

def format_corrosion_timestamp(_), do: "Invalid timestamp"








  defp add_health_indicators(status) when is_map(status) do
    # Add computed health indicators based on status data
    # This would depend on what fields are available in cluster status output
    Map.put(status, "overall_health", compute_health(status))
  end

  @doc """
  Convenience function to get human-readable member summary.

  Returns a map with key information about a cluster member.
  """
  def summarize_member(member) when is_map(member) do
    %{
      id: Map.get(member, "display_id", "unknown"),
      address: Map.get(member, "display_addr", "unknown"),
      status: Map.get(member, "display_status", "unknown"),
      cluster_id: Map.get(member, "display_cluster_id"),
      ring: Map.get(member, "display_ring"),
      last_sync: Map.get(member, "display_last_sync", "never"),
      avg_rtt: Map.get(member, "display_rtt_avg"),
      rtt_samples: Map.get(member, "display_rtt_count", 0)
    }
  end

  @doc """
  Helper function to check if a member appears to be actively participating in the cluster.
  """
  def active_member?(member) when is_map(member) do
    has_recent_sync =
      case get_in(member, ["state", "last_sync_ts"]) do
        ts when is_integer(ts) ->
          # Check if sync was within last 5 minutes
          five_minutes_ago =
            (DateTime.utc_now() |> DateTime.to_unix(:nanosecond)) - 5 * 60 * 1_000_000_000

          ts > five_minutes_ago

        _ ->
          false
      end

    has_address =
      case get_in(member, ["state", "addr"]) do
        addr when is_binary(addr) -> String.length(addr) > 0
        _ -> false
      end

    has_recent_sync and has_address
  end

  @doc """
  Extracts region information from cluster members.
  Returns a map of node_id -> region for geographic display.
  """
  def extract_cluster_regions(members) when is_list(members) do
    members
    |> Enum.map(fn member ->
      node_id = CorroPort.AckTracker.member_to_node_id(member)
      region = extract_region_from_node_id(node_id)
      {node_id, region}
    end)
    |> Enum.reject(fn {node_id, _region} -> is_nil(node_id) end)
    |> Enum.into(%{})
  end

  @doc """
  Extracts region from a node ID.
  Expects format: "region-machine_id" or falls back to extracting from node pattern.
  """
  def extract_region_from_node_id(node_id) when is_binary(node_id) do
    case String.split(node_id, "-", parts: 2) do
      [region, _machine_id] ->
        # Use regular function call instead of guard
        if region in valid_fly_regions() or region == "dev" do
          region
        else
          "unknown"
        end

      _ ->
        # Fallback for development pattern like "node1"
        case Regex.run(~r/^node(\d+)$/, node_id) do
          [_, _num] -> "dev"
          _ -> "unknown"
        end
    end
  end

  def extract_region_from_node_id(nil), do: "unknown"
  def extract_region_from_node_id(_), do: "unknown"

  # Helper function to get valid regions at runtime
  defp valid_fly_regions do
    CorroPort.CityData.valid_fly_regions()
  end
end

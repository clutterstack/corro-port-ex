defmodule CorroPort.ClusterMemberPresenter do
  @moduledoc """
  Presentation helpers for Corrosion cluster member maps returned by the CLI.

  Keeps Phoenix-facing transformations out of the shared `corro_cli` dependency so
  they can evolve with the UI without impacting the CLI tool.
  """

  alias CorroCLI.TimeUtils

  @doc """
  Enrich a list of raw member maps with display-oriented fields.
  """
  @spec present_members(list(map())) :: list(map())
  def present_members(members) when is_list(members) do
    Enum.map(members, &present_member/1)
  end

  def present_members(_), do: []

  @doc """
  Enrich a single member map with display fields.
  """
  @spec present_member(map()) :: map()
  def present_member(member) when is_map(member) do
    member
    |> add_display_fields()
    |> add_status_badge_class()
  end

  def present_member(other), do: other

  @doc """
  Convenience summary of key display fields for a presented member.
  """
  @spec summarize_member(map()) :: map()
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

  def summarize_member(_), do: %{}

  @doc """
  Heuristic to decide whether a member looks active based on sync timestamp and address.
  """
  @spec active_member?(map()) :: boolean()
  def active_member?(member) when is_map(member) do
    has_recent_sync =
      case get_in(member, ["state", "last_sync_ts"]) do
        ts when is_integer(ts) ->
          five_minutes_ago =
            DateTime.utc_now()
            |> DateTime.to_unix(:nanosecond)
            |> Kernel.-(5 * 60 * 1_000_000_000)

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

  def active_member?(_), do: false

  defp add_display_fields(member) do
    state = Map.get(member, "state", %{})
    rtts = Map.get(member, "rtts") || []

    short_id =
      case Map.get(member, "id") do
        id when is_binary(id) and byte_size(id) > 8 -> String.slice(id, 0, 8) <> "..."
        id -> id || "unknown"
      end

    parsed_addr = Map.get(state, "addr", "unknown")

    computed_status =
      cond do
        Map.get(state, "last_sync_ts") != nil -> "active"
        Map.get(state, "ts") != nil -> "connected"
        parsed_addr != "unknown" -> "reachable"
        true -> "unknown"
      end

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

    formatted_last_sync =
      case Map.get(state, "last_sync_ts") do
        ts when is_integer(ts) -> TimeUtils.format_corrosion_timestamp(ts)
        _ -> "never"
      end

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
    badge_class =
      case Map.get(member, "display_status") do
        "active" -> "badge badge-sm badge-success"
        "connected" -> "badge badge-sm badge-info"
        "reachable" -> "badge badge-sm badge-warning"
        _ -> "badge badge-sm badge-neutral"
      end

    Map.put(member, "display_status_class", badge_class)
  end
end

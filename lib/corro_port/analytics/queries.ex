defmodule CorroPort.Analytics.Queries do
  @moduledoc """
  Analytical query functions for experiment data.

  This module contains complex analytical operations that build on top of
  the basic Analytics context. Functions here handle statistical calculations,
  aggregations, and time-series analysis.
  """

  import Ecto.Query
  alias CorroPort.Analytics.Repo
  alias CorroPort.Analytics.MessageEvent

  @doc """
  Calculates timing statistics for message propagation.
  """
  def get_message_timing_stats(experiment_id) do
    # Get send and ack events grouped by message
    events_query =
      from(e in MessageEvent,
        where: e.experiment_id == ^experiment_id,
        select: {e.message_id, e.event_type, e.event_timestamp, e.inserted_at, e.originating_node, e.target_node},
        order_by: [e.message_id, e.event_timestamp]
      )

    events = Repo.all(events_query)

    # Group by message and calculate timing
    events
    # Group by message_id
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {message_id, message_events} ->
      calculate_message_timing(message_id, message_events)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp calculate_message_timing(message_id, events) do
    send_event = Enum.find(events, fn {_, event_type, _, _, _, _} -> event_type == :sent end)
    ack_events = Enum.filter(events, fn {_, event_type, _, _, _, _} -> event_type == :acked end)

    case send_event do
      {_, :sent, event_timestamp, _, originating_node, _} ->
        ack_timings =
          Enum.map(ack_events, fn {_, :acked, ack_timestamp, _, _, target_node} ->
            diff_ms = DateTime.diff(ack_timestamp, event_timestamp, :millisecond)
            %{target_node: target_node, latency_ms: diff_ms}
          end)

        %{
          message_id: message_id,
          originating_node: originating_node,
          send_time: event_timestamp,
          ack_count: length(ack_timings),
          acknowledgments: ack_timings,
          min_latency_ms: ack_timings |> Enum.map(& &1.latency_ms) |> Enum.min(fn -> nil end),
          max_latency_ms: ack_timings |> Enum.map(& &1.latency_ms) |> Enum.max(fn -> nil end),
          avg_latency_ms:
            case ack_timings do
              [] ->
                nil

              latencies ->
                latencies |> Enum.map(& &1.latency_ms) |> Enum.sum() |> div(length(latencies))
            end
        }

      _ ->
        nil
    end
  end

  @doc """
  Calculates per-node performance statistics showing RTT from message send to acknowledgement.

  Returns a list of maps with the following structure:
  - node_id: The node identifier
  - ack_count: Total number of acknowledgements received from this node
  - min_latency_ms: Minimum RTT in milliseconds
  - max_latency_ms: Maximum RTT in milliseconds
  - avg_latency_ms: Average RTT in milliseconds
  - p50_latency_ms: 50th percentile (median) RTT
  - p95_latency_ms: 95th percentile RTT
  - p99_latency_ms: 99th percentile RTT
  """
  def get_node_performance_stats(experiment_id) do
    timing_stats = get_message_timing_stats(experiment_id)

    # Aggregate by target node
    timing_stats
    |> Enum.flat_map(fn stat ->
      # For each message, extract all acknowledgments with their latencies
      Enum.map(stat.acknowledgments, fn ack ->
        %{
          target_node: ack.target_node,
          latency_ms: ack.latency_ms
        }
      end)
    end)
    |> Enum.group_by(& &1.target_node)
    |> Enum.map(fn {node_id, acks} ->
      latencies = Enum.map(acks, & &1.latency_ms)

      %{
        node_id: node_id,
        ack_count: length(acks),
        min_latency_ms: Enum.min(latencies),
        max_latency_ms: Enum.max(latencies),
        avg_latency_ms: Float.round(Enum.sum(latencies) / length(latencies), 1),
        p50_latency_ms: calculate_percentile(latencies, 50),
        p95_latency_ms: calculate_percentile(latencies, 95),
        p99_latency_ms: calculate_percentile(latencies, 99)
      }
    end)
    |> Enum.sort_by(& &1.avg_latency_ms)
  end

  @doc """
  Generates a latency histogram for an experiment.

  Returns a map containing:
  - buckets: List of histogram buckets with ranges and counts
  - percentiles: P50, P95, P99 values
  - total_count: Total number of data points
  - max_count: Maximum count in any bucket (for scaling visualisation)

  Options:
  - :bucket_edges - Custom bucket edges in milliseconds (default: linear 50ms increments up to the nearest bucket covering the maximum latency)
  """
  def get_latency_histogram(experiment_id, opts \\ []) do
    timing_stats = get_message_timing_stats(experiment_id)

    # Extract all latencies
    all_latencies =
      timing_stats
      |> Enum.flat_map(fn stat ->
        Enum.map(stat.acknowledgments, & &1.latency_ms)
      end)

    if all_latencies == [] do
      %{
        buckets: [],
        percentiles: %{p50: nil, p95: nil, p99: nil},
        total_count: 0,
        max_count: 0
      }
    else
      # Define bucket edges (in milliseconds)
      max_latency = Enum.max(all_latencies)
      bucket_edges =
        Keyword.get(opts, :bucket_edges, default_latency_bucket_edges(max_latency))

      # Create buckets
      buckets = create_histogram_buckets(all_latencies, bucket_edges)

      # Calculate percentiles
      percentiles = %{
        p50: calculate_percentile(all_latencies, 50),
        p95: calculate_percentile(all_latencies, 95),
        p99: calculate_percentile(all_latencies, 99)
      }

      max_count = buckets |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

      %{
        buckets: buckets,
        percentiles: percentiles,
        total_count: length(all_latencies),
        max_count: max_count
      }
    end
  end

  @doc """
  Analyzes message receipt time distribution across nodes relative to experiment start.

  Calculates receipt times relative to the first message send time to show the actual
  temporal pattern of message arrivals. This reveals batching behaviour as messages
  received together will have similar Y-axis values (time since experiment start).

  Returns a map containing:
  - per_node: List of per-node statistics including receipt time offsets from experiment start
  - overall_stats: Aggregated statistics across all nodes
  - experiment_start_time: The baseline timestamp (first message send time)
  """
  def get_receipt_time_distribution(experiment_id) do
    # Get send events for this experiment
    send_events_query =
      from(e in MessageEvent,
        where: e.experiment_id == ^experiment_id and e.event_type == :sent,
        select: {e.message_id, e.originating_node, e.event_timestamp},
        order_by: [asc: e.event_timestamp]
      )

    send_events_list = Repo.all(send_events_query)
    send_events = Map.new(send_events_list, fn {msg_id, node, ts} -> {msg_id, {node, ts}} end)

    # Get all ack events with receipt timestamps
    ack_events_query =
      from(e in MessageEvent,
        where:
          e.experiment_id == ^experiment_id and
            e.event_type == :acked and
            not is_nil(e.receipt_timestamp),
        select: {e.message_id, e.originating_node, e.target_node, e.event_timestamp, e.receipt_timestamp, e.region},
        order_by: [e.message_id, e.receipt_timestamp]
      )

    ack_events = Repo.all(ack_events_query)

    if ack_events == [] or send_events_list == [] do
      %{
        per_node: [],
        overall_stats: %{total_events: 0},
        experiment_start_time: nil
      }
    else
      # Get the first message send time as the baseline
      {_first_msg_id, _first_node, experiment_start_time} = List.first(send_events_list)

      # Calculate receipt time offsets relative to experiment start
      enriched_events =
        ack_events
        |> Enum.map(fn {msg_id, origin_node, target_node, _ack_ts, receipt_ts, region} ->
          case Map.get(send_events, msg_id) do
            {^origin_node, _send_ts} ->
              # Calculate time offset from experiment start (using receipt timestamp)
              time_offset_ms = DateTime.diff(receipt_ts, experiment_start_time, :millisecond)
              {msg_id, origin_node, target_node, receipt_ts, time_offset_ms, region}

            _ ->
              # No matching send event or different node
              {msg_id, origin_node, target_node, receipt_ts, nil, region}
          end
        end)

      per_node_stats = calculate_per_node_receipt_time_stats(enriched_events, experiment_start_time)
      overall_stats = calculate_overall_receipt_time_stats(enriched_events)

      %{
        per_node: per_node_stats,
        overall_stats: overall_stats,
        experiment_start_time: experiment_start_time
      }
    end
  end

  @doc """
  Gets receipt time series data organised by receiving node.

  Returns a list of maps, one per node, containing:
  - node_id: The receiving node identifier
  - data_points: List of %{send_time: DateTime, receipt_time: DateTime, propagation_delay_ms: integer}

  Shows when messages actually arrived at each node via gossip, allowing visualization
  of propagation patterns over the course of the experiment.
  """
  def get_receipt_time_series(experiment_id) do
    # Get send events
    send_events_query =
      from(e in MessageEvent,
        where: e.experiment_id == ^experiment_id and e.event_type == :sent,
        select: {e.message_id, e.originating_node, e.event_timestamp}
      )

    send_events = Repo.all(send_events_query) |> Map.new(fn {msg_id, node, ts} -> {msg_id, {node, ts}} end)

    # Get ack events with receipt timestamps
    ack_events_query =
      from(e in MessageEvent,
        where:
          e.experiment_id == ^experiment_id and
            e.event_type == :acked and
            not is_nil(e.receipt_timestamp),
        select: {e.message_id, e.originating_node, e.target_node, e.receipt_timestamp},
        order_by: [e.receipt_timestamp]
      )

    ack_events = Repo.all(ack_events_query)

    # Build time series per node
    ack_events
    |> Enum.map(fn {msg_id, origin_node, target_node, receipt_time} ->
      case Map.get(send_events, msg_id) do
        {^origin_node, send_time} ->
          delay_ms = DateTime.diff(receipt_time, send_time, :millisecond)
          %{
            node_id: target_node,
            send_time: send_time,
            receipt_time: receipt_time,
            propagation_delay_ms: delay_ms
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.node_id)
    |> Enum.map(fn {node_id, points} ->
      %{
        node_id: node_id,
        data_points: points
      }
    end)
    |> Enum.sort_by(& &1.node_id)
  end

  @doc """
  Gets RTT time series data organised by responding node.

  Returns a list of maps, one per node, containing:
  - node_id: The responding node identifier
  - data_points: List of %{send_time: DateTime, rtt_ms: integer} sorted by send_time

  This data can be used to plot RTT vs time to see if response times degrade
  as nodes get busier during the experiment.
  """
  def get_rtt_time_series(experiment_id) do
    timing_stats = get_message_timing_stats(experiment_id)

    # Extract all acknowledgements with their send times and RTTs
    timing_stats
    |> Enum.flat_map(fn stat ->
      # For each message, create data points for each acknowledgement
      Enum.map(stat.acknowledgments, fn ack ->
        %{
          node_id: ack.target_node,
          send_time: stat.send_time,
          rtt_ms: ack.latency_ms
        }
      end)
    end)
    |> Enum.group_by(& &1.node_id)
    |> Enum.map(fn {node_id, points} ->
      # Sort by send_time for each node
      sorted_points =
        points
        |> Enum.map(fn p -> %{send_time: p.send_time, rtt_ms: p.rtt_ms} end)
        |> Enum.sort_by(& &1.send_time, DateTime)

      %{
        node_id: node_id,
        data_points: sorted_points
      }
    end)
    |> Enum.sort_by(& &1.node_id)
  end

  # Private helpers

  defp calculate_per_node_receipt_time_stats(enriched_events, _experiment_start_time) do
    enriched_events
    |> Enum.group_by(&elem(&1, 2))
    |> Enum.map(fn {node_id, node_events} ->
      receipt_times = Enum.map(node_events, &elem(&1, 3))
      first_receipt = Enum.min(receipt_times, DateTime)
      last_receipt = Enum.max(receipt_times, DateTime)

      # Extract time offsets from experiment start (only non-nil values)
      # Preserve temporal order from the query (ordered by message_id, receipt_timestamp)
      time_offsets_temporal =
        node_events
        |> Enum.map(&elem(&1, 4))
        |> Enum.reject(&is_nil/1)

      receipt_time_stats =
        if time_offsets_temporal != [] do
          sorted_offsets = Enum.sort(time_offsets_temporal)

          %{
            min_delay_ms: Enum.min(sorted_offsets),
            max_delay_ms: Enum.max(sorted_offsets),
            p95_delay_ms: calculate_percentile(sorted_offsets, 95),
            delays: time_offsets_temporal  # Keep temporal order for visualization (these are time offsets, not delays)
          }
        else
          nil
        end

      %{
        node_id: node_id,
        total_messages: length(node_events),
        first_receipt: first_receipt,
        last_receipt: last_receipt,
        time_span_seconds: DateTime.diff(last_receipt, first_receipt, :second),
        propagation_delay_stats: receipt_time_stats  # Keep name for backward compatibility
      }
    end)
    |> Enum.sort_by(& &1.node_id)
  end

  defp calculate_overall_receipt_time_stats(enriched_events) do
    total_events = length(enriched_events)

    # Extract all time offsets from experiment start (only non-nil)
    all_time_offsets =
      enriched_events
      |> Enum.map(&elem(&1, 4))
      |> Enum.reject(&is_nil/1)

    # Count unique messages
    unique_messages =
      enriched_events
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> length()

    if all_time_offsets == [] do
      %{
        total_events: total_events,
        total_messages: unique_messages,
        avg_spread_ms: 0,
        p95_spread_ms: 0
      }
    else
      sorted_offsets = Enum.sort(all_time_offsets)

      %{
        total_events: total_events,
        total_messages: unique_messages,
        avg_spread_ms: Float.round(Enum.sum(sorted_offsets) / length(sorted_offsets), 1),
        p50_spread_ms: calculate_percentile(sorted_offsets, 50),
        p95_spread_ms: calculate_percentile(sorted_offsets, 95),
        min_delay_ms: Enum.min(sorted_offsets),
        max_delay_ms: Enum.max(sorted_offsets)
      }
    end
  end

  # Backward compatibility alias

  defp calculate_percentile(list, percentile) do
    sorted = Enum.sort(list)
    count = length(sorted)
    index = Float.round(count * percentile / 100) |> trunc()
    index = max(0, min(index, count - 1))
    Enum.at(sorted, index)
  end

  defp create_histogram_buckets(values, edges) do
    # Create bucket ranges
    bucket_ranges =
      edges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [min_val, max_val] -> {min_val, max_val} end)

    # Add final bucket for values >= last edge
    last_edge = List.last(edges)
    bucket_ranges = bucket_ranges ++ [{last_edge, :infinity}]

    # Count values in each bucket
    Enum.map(bucket_ranges, fn
      {min_val, :infinity} ->
        count = Enum.count(values, &(&1 >= min_val))

        %{
          min: min_val,
          max: :infinity,
          label: "#{min_val}ms+",
          count: count
        }

      {min_val, max_val} ->
        count = Enum.count(values, &(&1 >= min_val and &1 < max_val))

        %{
          min: min_val,
          max: max_val,
          label: "#{min_val}-#{max_val}ms",
          count: count
        }
    end)
  end

  defp default_latency_bucket_edges(max_latency) do
    bucket_size = 50

    highest_edge =
      cond do
        max_latency <= 0 -> bucket_size
        rem(max_latency, bucket_size) == 0 -> max_latency
        true -> max_latency + (bucket_size - rem(max_latency, bucket_size))
      end

    0
    |> Stream.iterate(&(&1 + bucket_size))
    |> Enum.take_while(&(&1 <= highest_edge))
  end
end

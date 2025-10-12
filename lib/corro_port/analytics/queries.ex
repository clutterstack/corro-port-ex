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
  - :bucket_edges - Custom bucket edges in milliseconds (default: [0, 10, 20, 50, 100, 200, 500, 1000, 5000])
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
      bucket_edges = Keyword.get(opts, :bucket_edges, [0, 10, 20, 50, 100, 200, 500, 1000, 5000])

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
end

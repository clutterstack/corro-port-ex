defmodule CorroPort.Analytics.Exporter do
  @moduledoc """
  Export analytics experiment data in various formats for analysis and comparison.

  Provides comprehensive export functionality that captures experiment configuration,
  performance metrics, system health data, and raw events for external analysis.

  Supported formats:
  - `:json` - Complete nested structure, suitable for programmatic processing and re-import
  - `:csv` - Flattened summary suitable for spreadsheet analysis

  ## Examples

      # Export single experiment as JSON
      {:ok, json_data} = Exporter.export_experiment("exp123", :json)

      # Export multiple experiments for comparison
      {:ok, csv_data} = Exporter.export_comparison(["exp1", "exp2", "exp3"], :csv)

  """

  alias CorroPort.Analytics
  alias CorroPort.Analytics.Queries
  alias CorroPort.LocalNode

  require Logger

  @exporter_version "1.0.0"

  @doc """
  Export a single experiment with complete detail.

  Returns `{:ok, data}` where data format depends on the format parameter:
  - `:json` returns a nested map structure
  - `:csv` returns a CSV string

  Options:
  - `:include_raw_events` - Include all raw message events (default: true)
  - `:include_system_metrics` - Include detailed system metrics (default: true)
  """
  def export_experiment(experiment_id, format \\ :json, opts \\ []) do
    include_raw_events = Keyword.get(opts, :include_raw_events, true)
    include_system_metrics = Keyword.get(opts, :include_system_metrics, true)

    Logger.info("Exporting experiment #{experiment_id} as #{format}")

    try do
      # Gather all experiment data
      summary = Analytics.get_experiment_summary(experiment_id)
      topology_snapshots = Analytics.get_topology_snapshots(experiment_id)
      timing_stats = Queries.get_message_timing_stats(experiment_id)
      node_performance = Queries.get_node_performance_stats(experiment_id)
      latency_histogram = Queries.get_latency_histogram(experiment_id)
      rtt_time_series = Queries.get_rtt_time_series(experiment_id)

      # Optional detailed data
      raw_events =
        if include_raw_events do
          Analytics.get_message_events(experiment_id)
        else
          []
        end

      system_metrics =
        if include_system_metrics do
          Analytics.get_system_metrics(experiment_id)
        else
          []
        end

      # Build complete export structure
      export_data = %{
        metadata: build_metadata(),
        experiment: build_experiment_info(summary, topology_snapshots),
        topology: build_topology_info(topology_snapshots),
        performance: build_performance_info(summary, timing_stats, node_performance, latency_histogram, rtt_time_series),
        system_metrics: serialize_system_metrics(system_metrics),
        raw_events: serialize_raw_events(raw_events)
      }

      # Format output
      case format do
        :json ->
          {:ok, export_data}

        :csv ->
          {:ok, format_as_csv(export_data)}

        _ ->
          {:error, "Unsupported format: #{format}. Use :json or :csv"}
      end
    rescue
      error ->
        Logger.error("Failed to export experiment #{experiment_id}: #{inspect(error)}")
        {:error, "Export failed: #{Exception.message(error)}"}
    end
  end

  @doc """
  Export multiple experiments as a comparison summary.

  Returns a summary table with key metrics for each experiment,
  suitable for side-by-side comparison.
  """
  def export_comparison(experiment_ids, format \\ :json) do
    Logger.info("Exporting comparison for #{length(experiment_ids)} experiments")

    try do
      summaries =
        Enum.map(experiment_ids, fn exp_id ->
          build_experiment_summary(exp_id)
        end)

      comparison_data = %{
        metadata: build_metadata(),
        experiment_count: length(summaries),
        experiments: summaries
      }

      case format do
        :json ->
          {:ok, comparison_data}

        :csv ->
          {:ok, format_comparison_csv(summaries)}

        _ ->
          {:error, "Unsupported format: #{format}"}
      end
    rescue
      error ->
        Logger.error("Failed to export comparison: #{inspect(error)}")
        {:error, "Comparison export failed: #{Exception.message(error)}"}
    end
  end

  @doc """
  List all available experiments with basic info.
  """
  def list_available_experiments do
    experiment_ids = Analytics.list_experiments()

    experiments =
      Enum.map(experiment_ids, fn exp_id ->
        summary = Analytics.get_experiment_summary(exp_id)

        %{
          experiment_id: exp_id,
          message_count: summary.message_count,
          send_count: summary.send_count,
          ack_count: summary.ack_count,
          time_range: summary.time_range
        }
      end)

    {:ok, experiments}
  end

  # Private Functions - Data Builders

  defp build_metadata do
    %{
      exported_at: DateTime.utc_now(),
      exporter_version: @exporter_version,
      node_id: LocalNode.get_node_id(),
      region: LocalNode.get_region()
    }
  end

  defp build_experiment_info(summary, topology_snapshots) do
    # Calculate experiment duration
    duration_seconds =
      case summary.time_range do
        %{start: start_time, end: end_time} ->
          DateTime.diff(end_time, start_time, :second)

        _ ->
          nil
      end

    # Extract configuration from topology snapshots
    config_snapshot = List.first(topology_snapshots)

    %{
      id: summary.experiment_id,
      started_at: get_in(summary.time_range, [:start]),
      ended_at: get_in(summary.time_range, [:end]),
      duration_seconds: duration_seconds,
      message_count: summary.message_count,
      send_count: summary.send_count,
      ack_count: summary.ack_count,
      success_rate: calculate_success_rate(summary.send_count, summary.ack_count),
      configuration:
        if config_snapshot do
          %{
            transaction_size_bytes: config_snapshot.transaction_size_bytes,
            transaction_frequency_ms: config_snapshot.transaction_frequency_ms
          }
        else
          nil
        end
    }
  end

  defp build_topology_info(topology_snapshots) do
    nodes =
      Enum.map(topology_snapshots, fn snapshot ->
        %{
          node_id: snapshot.node_id,
          region: CorroPort.NodeNaming.extract_region_from_node_id(snapshot.node_id),
          bootstrap_peers: snapshot.bootstrap_peers,
          transaction_size_bytes: snapshot.transaction_size_bytes,
          transaction_frequency_ms: snapshot.transaction_frequency_ms,
          snapshot_time: snapshot.inserted_at
        }
      end)

    unique_regions =
      nodes
      |> Enum.map(& &1.region)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      node_count: length(nodes),
      nodes: nodes,
      regions: unique_regions,
      region_count: length(unique_regions)
    }
  end

  defp build_performance_info(summary, timing_stats, node_performance, latency_histogram, rtt_time_series) do
    # Calculate aggregate latencies from timing stats
    all_latencies =
      timing_stats
      |> Enum.map(& &1.min_latency_ms)
      |> Enum.reject(&is_nil/1)

    latency_summary =
      if all_latencies != [] do
        sorted = Enum.sort(all_latencies)

        %{
          min_ms: Enum.min(sorted),
          max_ms: Enum.max(sorted),
          avg_ms: Float.round(Enum.sum(sorted) / length(sorted), 2),
          median_ms: calculate_percentile(sorted, 50),
          p95_ms: calculate_percentile(sorted, 95),
          p99_ms: calculate_percentile(sorted, 99),
          sample_count: length(sorted)
        }
      else
        %{
          min_ms: nil,
          max_ms: nil,
          avg_ms: nil,
          median_ms: nil,
          p95_ms: nil,
          p99_ms: nil,
          sample_count: 0
        }
      end

    # Message flow patterns
    message_flows = analyze_message_flows(timing_stats)

    %{
      summary: %{
        total_messages: summary.message_count,
        send_count: summary.send_count,
        ack_count: summary.ack_count,
        success_rate: calculate_success_rate(summary.send_count, summary.ack_count)
      },
      latency: latency_summary,
      per_node_performance: node_performance,
      latency_histogram: latency_histogram,
      rtt_time_series:
        Enum.map(rtt_time_series, fn series ->
          # Limit time series data points for export size
          %{
            node_id: series.node_id,
            data_points: Enum.take(series.data_points, 1000)
          }
        end),
      message_flows: message_flows
    }
  end

  defp serialize_system_metrics(metrics) do
    Enum.map(metrics, fn metric ->
      %{
        node_id: metric.node_id,
        cpu_percent: metric.cpu_percent,
        memory_mb: metric.memory_mb,
        erlang_processes: metric.erlang_processes,
        corrosion_connections: metric.corrosion_connections,
        message_queue_length: metric.message_queue_length,
        timestamp: metric.inserted_at
      }
    end)
  end

  defp serialize_raw_events(events) do
    Enum.map(events, fn event ->
      %{
        message_id: event.message_id,
        originating_node: event.originating_node,
        target_node: event.target_node,
        event_type: event.event_type,
        event_timestamp: event.event_timestamp,
        region: event.region,
        transaction_size_hint: event.transaction_size_hint
      }
    end)
  end

  defp analyze_message_flows(timing_stats) do
    # Group by originating node to show message distribution
    timing_stats
    |> Enum.group_by(& &1.originating_node)
    |> Enum.map(fn {node, messages} ->
      total_acks =
        messages
        |> Enum.map(& &1.ack_count)
        |> Enum.sum()

      avg_acks_per_message =
        if length(messages) > 0 do
          Float.round(total_acks / length(messages), 2)
        else
          0
        end

      %{
        originating_node: node,
        messages_sent: length(messages),
        total_acks_received: total_acks,
        avg_acks_per_message: avg_acks_per_message
      }
    end)
    |> Enum.sort_by(& &1.messages_sent, :desc)
  end

  defp build_experiment_summary(experiment_id) do
    summary = Analytics.get_experiment_summary(experiment_id)
    timing_stats = Queries.get_message_timing_stats(experiment_id)
    topology = Analytics.get_topology_snapshots(experiment_id)

    # Calculate basic latency stats
    all_latencies =
      timing_stats
      |> Enum.map(& &1.min_latency_ms)
      |> Enum.reject(&is_nil/1)

    latency_avg =
      if all_latencies != [] do
        Float.round(Enum.sum(all_latencies) / length(all_latencies), 2)
      else
        nil
      end

    latency_p95 =
      if all_latencies != [] do
        calculate_percentile(Enum.sort(all_latencies), 95)
      else
        nil
      end

    duration_seconds =
      case summary.time_range do
        %{start: start_time, end: end_time} -> DateTime.diff(end_time, start_time, :second)
        _ -> nil
      end

    %{
      experiment_id: experiment_id,
      started_at: get_in(summary.time_range, [:start]),
      duration_seconds: duration_seconds,
      node_count: length(topology),
      message_count: summary.send_count,
      ack_count: summary.ack_count,
      success_rate: calculate_success_rate(summary.send_count, summary.ack_count),
      avg_latency_ms: latency_avg,
      p95_latency_ms: latency_p95
    }
  end

  # Private Functions - CSV Formatting

  defp format_as_csv(export_data) do
    sections = [
      "# Experiment Export - #{export_data.experiment.id}",
      "# Exported at: #{export_data.metadata.exported_at}",
      "",
      "## Experiment Summary",
      csv_section_experiment(export_data.experiment),
      "",
      "## Topology",
      csv_section_topology(export_data.topology),
      "",
      "## Performance Summary",
      csv_section_performance(export_data.performance),
      "",
      "## Per-Node Performance",
      csv_section_node_performance(export_data.performance.per_node_performance),
      "",
      "## Latency Histogram",
      csv_section_histogram(export_data.performance.latency_histogram)
    ]

    Enum.join(sections, "\n")
  end

  defp csv_section_experiment(exp) do
    """
    Field,Value
    Experiment ID,#{exp.id}
    Started At,#{exp.started_at}
    Ended At,#{exp.ended_at}
    Duration (seconds),#{exp.duration_seconds}
    Message Count,#{exp.message_count}
    Send Count,#{exp.send_count}
    Ack Count,#{exp.ack_count}
    Success Rate,#{format_percentage(exp.success_rate)}
    """
    |> String.trim()
  end

  defp csv_section_topology(topology) do
    header = "Node ID,Region,Bootstrap Peers Count,Transaction Size (bytes),Transaction Frequency (ms)"

    rows =
      Enum.map(topology.nodes, fn node ->
        peer_count = length(node.bootstrap_peers || [])

        "#{node.node_id},#{node.region},#{peer_count},#{node.transaction_size_bytes},#{node.transaction_frequency_ms}"
      end)

    [header | rows]
    |> Enum.join("\n")
  end

  defp csv_section_performance(perf) do
    """
    Metric,Value
    Total Messages,#{perf.summary.total_messages}
    Send Count,#{perf.summary.send_count}
    Ack Count,#{perf.summary.ack_count}
    Success Rate,#{format_percentage(perf.summary.success_rate)}
    Min Latency (ms),#{perf.latency.min_ms}
    Max Latency (ms),#{perf.latency.max_ms}
    Avg Latency (ms),#{perf.latency.avg_ms}
    Median Latency (ms),#{perf.latency.median_ms}
    P95 Latency (ms),#{perf.latency.p95_ms}
    P99 Latency (ms),#{perf.latency.p99_ms}
    """
    |> String.trim()
  end

  defp csv_section_node_performance(nodes) do
    header = "Node ID,Ack Count,Min Latency (ms),Max Latency (ms),Avg Latency (ms),P50 (ms),P95 (ms),P99 (ms)"

    rows =
      Enum.map(nodes, fn node ->
        "#{node.node_id},#{node.ack_count},#{node.min_latency_ms},#{node.max_latency_ms},#{node.avg_latency_ms},#{node.p50_latency_ms},#{node.p95_latency_ms},#{node.p99_latency_ms}"
      end)

    [header | rows]
    |> Enum.join("\n")
  end

  defp csv_section_histogram(histogram) do
    header = "Latency Range,Count"

    rows =
      Enum.map(histogram.buckets, fn bucket ->
        "#{bucket.label},#{bucket.count}"
      end)

    [header | rows]
    |> Enum.join("\n")
  end

  defp format_comparison_csv(summaries) do
    header = "Experiment ID,Started At,Duration (s),Nodes,Messages,Acks,Success Rate,Avg Latency (ms),P95 Latency (ms)"

    rows =
      Enum.map(summaries, fn summary ->
        "#{summary.experiment_id},#{summary.started_at},#{summary.duration_seconds},#{summary.node_count},#{summary.message_count},#{summary.ack_count},#{format_percentage(summary.success_rate)},#{summary.avg_latency_ms},#{summary.p95_latency_ms}"
      end)

    [header | rows]
    |> Enum.join("\n")
  end

  # Private Functions - Utilities

  defp calculate_success_rate(send_count, ack_count) when send_count > 0 do
    Float.round(ack_count / send_count * 100, 2)
  end

  defp calculate_success_rate(_, _), do: 0.0

  defp calculate_percentile(sorted_list, percentile) do
    count = length(sorted_list)
    index = Float.round(count * percentile / 100) |> trunc()
    index = max(0, min(index - 1, count - 1))
    Enum.at(sorted_list, index)
  end

  defp format_percentage(nil), do: "N/A"
  defp format_percentage(value), do: "#{value}%"
end

defmodule CorroPortWeb.AnalyticsLive.DataLoader do
  @moduledoc """
  Data loading and calculation logic for AnalyticsLive.

  Handles:
  - Loading experiment data from AnalyticsAggregator
  - Loading experiment history from Analytics
  - Calculating acknowledgment rates
  - Determining node counts for ack rate calculations
  """

  alias CorroPort.{AnalyticsAggregator, Analytics, LocalNode}
  alias CorroPort.Analytics.Queries
  alias CorroPortWeb.AnalyticsLive.Helpers

  @doc """
  Loads all experiment data for the current experiment and updates socket assigns.

  Fetches:
  - Cluster summary
  - Timing statistics
  - System metrics
  - Active nodes
  - Node performance stats
  - Latency histogram
  - RTT time series

  Returns the socket if no current experiment is set.
  """
  def load_experiment_data(socket) do
    if socket.assigns.current_experiment do
      experiment_id = socket.assigns.current_experiment

      # Get data from aggregator
      cluster_summary =
        case AnalyticsAggregator.get_cluster_experiment_summary(experiment_id) do
          {:ok, summary} -> summary
          _ -> nil
        end

      timing_stats =
        case AnalyticsAggregator.get_cluster_timing_stats(experiment_id) do
          {:ok, stats} -> stats
          _ -> []
        end

      system_metrics =
        case AnalyticsAggregator.get_cluster_system_metrics(experiment_id) do
          {:ok, metrics} -> Enum.sort_by(metrics, & &1.inserted_at, {:desc, DateTime})
          _ -> []
        end

      active_nodes = AnalyticsAggregator.get_active_nodes()

      # Get per-node performance statistics
      node_performance_stats = Queries.get_node_performance_stats(experiment_id)

      # Get latency histogram
      latency_histogram = Queries.get_latency_histogram(experiment_id)

      # Get RTT time series
      rtt_time_series = Queries.get_rtt_time_series(experiment_id)

      socket
      |> Phoenix.Component.assign(:cluster_summary, cluster_summary)
      |> Phoenix.Component.assign(:timing_stats, timing_stats)
      |> Phoenix.Component.assign(:system_metrics, system_metrics)
      |> Phoenix.Component.assign(:active_nodes, active_nodes)
      |> Phoenix.Component.assign(:node_performance_stats, node_performance_stats)
      |> Phoenix.Component.assign(:latency_histogram, latency_histogram)
      |> Phoenix.Component.assign(:rtt_time_series, rtt_time_series)
      |> Phoenix.Component.assign(:last_update, DateTime.utc_now())
    else
      socket
    end
  end

  @doc """
  Loads experiment history and updates socket assigns.

  Fetches all experiments, enriches with summary data, and sorts by start time.
  """
  def load_experiment_history(socket) do
    # Get list of all experiments and enrich with summary data
    experiment_ids = Analytics.list_experiments()

    history =
      experiment_ids
      |> Enum.map(fn exp_id ->
        summary = Analytics.get_experiment_summary(exp_id)

        %{
          id: exp_id,
          send_count: summary.send_count,
          ack_count: summary.ack_count,
          time_range: summary.time_range,
          duration_seconds: Helpers.calculate_duration(summary.time_range)
        }
      end)
      |> Enum.sort_by(
        fn exp ->
          case exp.time_range do
            %{start: start} -> start
            _ -> ~U[1970-01-01 00:00:00Z]
          end
        end,
        {:desc, DateTime}
      )

    Phoenix.Component.assign(socket, :experiment_history, history)
  end

  @doc """
  Calculates the acknowledgment rate as a percentage.

  Takes into account the number of messages sent and the expected number
  of remote nodes that should acknowledge each message.

  Returns 0.0 if summary is nil or if no messages have been sent.
  """
  def ack_rate(summary, opts \\ [])
  def ack_rate(nil, _opts), do: 0.0

  def ack_rate(summary, opts) do
    send_count = Map.get(summary, :send_count, 0)
    ack_count = Map.get(summary, :ack_count, 0)
    expected_acks = send_count * ack_node_count(summary, opts)

    if expected_acks > 0 do
      Float.round(ack_count / expected_acks * 100, 1)
    else
      0.0
    end
  end

  @doc """
  Determines the number of nodes expected to acknowledge messages.

  Tries multiple strategies in order:
  1. Use explicit remote_node_count from summary if available
  2. Calculate from active_nodes list (excluding local node)
  3. Fall back to total node_count minus 1 (assuming local node doesn't ack itself)

  Returns 0 if no valid node count can be determined.
  """
  def ack_node_count(summary, opts) do
    cond do
      is_integer(Map.get(summary, :remote_node_count)) and
          Map.get(summary, :remote_node_count) >= 0 ->
        Map.get(summary, :remote_node_count)

      (remote_from_active = remote_count_from_active_nodes(opts)) != nil ->
        remote_from_active

      true ->
        case Map.get(summary, :node_count) do
          count when is_integer(count) and count > 0 ->
            remote = count - 1

            if remote < 0 do
              0
            else
              remote
            end

          _ ->
            0
        end
    end
  end

  @doc """
  Calculates the number of remote nodes from the active_nodes list.

  Excludes the local node (identified by local_node_id) from the count.

  Returns nil if:
  - active_nodes is not a list
  - active_nodes is empty
  - active_nodes is not provided in opts
  """
  def remote_count_from_active_nodes(opts) do
    active_nodes = Keyword.get(opts, :active_nodes)

    cond do
      not is_list(active_nodes) ->
        nil

      active_nodes == [] ->
        nil

      true ->
        local_node_id = Keyword.get(opts, :local_node_id)

        Enum.count(active_nodes, fn node ->
          node_id = Map.get(node, :node_id)
          node_id && node_id != local_node_id
        end)
    end
  end
end

defmodule CorroPort.Analytics do
  @moduledoc """
  Analytics context for managing experiment data, message timing events, and system metrics.

  This module provides a clean API for recording and querying analytics data
  using Ecto schemas and the Analytics.Repo.
  """

  import Ecto.Query
  alias CorroPort.Analytics.Repo
  alias CorroPort.Analytics.{TopologySnapshot, MessageEvent, SystemMetric}

  require Logger

  ## Topology Snapshots

  @doc """
  Creates a topology snapshot for an experiment.
  """
  def create_topology_snapshot(attrs) do
    %TopologySnapshot{}
    |> TopologySnapshot.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets topology snapshots for an experiment.
  """
  def get_topology_snapshots(experiment_id) do
    TopologySnapshot
    |> where([t], t.experiment_id == ^experiment_id)
    |> order_by([t], t.inserted_at)
    |> Repo.all()
  end

  ## Message Events

  @doc """
  Records a message timing event.
  """
  def record_message_event(attrs) do
    %MessageEvent{}
    |> MessageEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        Logger.debug("Recorded #{event.event_type} event for message #{event.message_id}")
        {:ok, event}

      {:error, changeset} ->
        Logger.error("Failed to record message event: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Gets message events for an experiment with optional filters.
  """
  def get_message_events(experiment_id, opts \\ []) do
    query =
      MessageEvent
      |> where([m], m.experiment_id == ^experiment_id)
      |> order_by([m], m.inserted_at)

    query =
      case Keyword.get(opts, :event_type) do
        nil -> query
        event_type -> where(query, [m], m.event_type == ^event_type)
      end

    Repo.all(query)
  end

  @doc """
  Calculates timing statistics for message propagation.
  """
  def get_message_timing_stats(experiment_id) do
    # Get send and ack events grouped by message
    events_query =
      from(e in MessageEvent,
        where: e.experiment_id == ^experiment_id,
        select: {e.message_id, e.event_type, e.inserted_at, e.originating_node, e.target_node},
        order_by: [e.message_id, e.inserted_at]
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
    send_event = Enum.find(events, fn {_, event_type, _, _, _} -> event_type == :sent end)
    ack_events = Enum.filter(events, fn {_, event_type, _, _, _} -> event_type == :acked end)

    case send_event do
      {_, :sent, send_time, originating_node, _} ->
        ack_timings =
          Enum.map(ack_events, fn {_, :acked, ack_time, _, target_node} ->
            diff_ms = DateTime.diff(ack_time, send_time, :millisecond)
            %{target_node: target_node, latency_ms: diff_ms}
          end)

        %{
          message_id: message_id,
          originating_node: originating_node,
          send_time: send_time,
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

  ## System Metrics

  @doc """
  Records system metrics.
  """
  def record_system_metrics(attrs) do
    %SystemMetric{}
    |> SystemMetric.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, metric} ->
        Logger.debug("Recorded system metrics for experiment #{metric.experiment_id}")
        {:ok, metric}

      {:error, changeset} ->
        Logger.error("Failed to record system metrics: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Gets system metrics for an experiment.
  """
  def get_system_metrics(experiment_id, opts \\ []) do
    query =
      SystemMetric
      |> where([s], s.experiment_id == ^experiment_id)
      |> order_by([s], s.inserted_at)

    query =
      case Keyword.get(opts, :node_id) do
        nil -> query
        node_id -> where(query, [s], s.node_id == ^node_id)
      end

    Repo.all(query)
  end

  ## Experiment Summary

  @doc """
  Gets summary statistics for an experiment.
  """
  def get_experiment_summary(experiment_id) do
    # Get counts
    message_count =
      MessageEvent
      |> where([m], m.experiment_id == ^experiment_id)
      |> Repo.aggregate(:count, :id)

    send_count =
      MessageEvent
      |> where([m], m.experiment_id == ^experiment_id and m.event_type == :sent)
      |> Repo.aggregate(:count, :id)

    ack_count =
      MessageEvent
      |> where([m], m.experiment_id == ^experiment_id and m.event_type == :acked)
      |> Repo.aggregate(:count, :id)

    topology_snapshots_count =
      TopologySnapshot
      |> where([t], t.experiment_id == ^experiment_id)
      |> Repo.aggregate(:count, :id)

    system_metrics_count =
      SystemMetric
      |> where([s], s.experiment_id == ^experiment_id)
      |> Repo.aggregate(:count, :id)

    # Get time range
    time_range = get_experiment_time_range(experiment_id)

    %{
      experiment_id: experiment_id,
      message_count: message_count,
      send_count: send_count,
      ack_count: ack_count,
      topology_snapshots_count: topology_snapshots_count,
      system_metrics_count: system_metrics_count,
      time_range: time_range
    }
  end

  defp get_experiment_time_range(experiment_id) do
    # Get earliest and latest timestamps across all tables
    earliest_query =
      from(m in MessageEvent,
        where: m.experiment_id == ^experiment_id,
        select: min(m.inserted_at)
      )

    latest_query =
      from(m in MessageEvent,
        where: m.experiment_id == ^experiment_id,
        select: max(m.inserted_at)
      )

    earliest = Repo.one(earliest_query)
    latest = Repo.one(latest_query)

    case {earliest, latest} do
      {nil, nil} -> nil
      {start_time, end_time} -> %{start: start_time, end: end_time}
    end
  end

  @doc """
  Lists all unique experiment IDs.
  """
  def list_experiments do
    # Get unique experiment IDs from all tables
    message_experiments =
      MessageEvent
      |> select([m], m.experiment_id)
      |> distinct(true)
      |> Repo.all()

    topology_experiments =
      TopologySnapshot
      |> select([t], t.experiment_id)
      |> distinct(true)
      |> Repo.all()

    (message_experiments ++ topology_experiments)
    |> Enum.uniq()
    |> Enum.sort()
  end
end

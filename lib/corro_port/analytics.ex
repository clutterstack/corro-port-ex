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

  ## Experiment Deletion

  @doc """
  Deletes all data for a specific experiment.

  This removes:
  - All message events
  - All topology snapshots
  - All system metrics

  Returns `{:ok, deleted_counts}` on success where deleted_counts is a map
  with counts of deleted records per table.
  """
  def delete_experiment(experiment_id) do
    Repo.transaction(fn ->
      message_events_deleted =
        MessageEvent
        |> where([m], m.experiment_id == ^experiment_id)
        |> Repo.delete_all()
        |> elem(0)

      topology_snapshots_deleted =
        TopologySnapshot
        |> where([t], t.experiment_id == ^experiment_id)
        |> Repo.delete_all()
        |> elem(0)

      system_metrics_deleted =
        SystemMetric
        |> where([s], s.experiment_id == ^experiment_id)
        |> Repo.delete_all()
        |> elem(0)

      Logger.info(
        "Deleted experiment #{experiment_id}: " <>
          "#{message_events_deleted} message events, " <>
          "#{topology_snapshots_deleted} topology snapshots, " <>
          "#{system_metrics_deleted} system metrics"
      )

      %{
        message_events: message_events_deleted,
        topology_snapshots: topology_snapshots_deleted,
        system_metrics: system_metrics_deleted
      }
    end)
  end

  @doc """
  Deletes all experiment data from all tables.

  Use with caution - this clears the entire analytics history.
  Returns `{:ok, deleted_counts}` on success.
  """
  def delete_all_experiments do
    Repo.transaction(fn ->
      message_events_deleted = Repo.delete_all(MessageEvent) |> elem(0)
      topology_snapshots_deleted = Repo.delete_all(TopologySnapshot) |> elem(0)
      system_metrics_deleted = Repo.delete_all(SystemMetric) |> elem(0)

      Logger.info(
        "Deleted all experiments: " <>
          "#{message_events_deleted} message events, " <>
          "#{topology_snapshots_deleted} topology snapshots, " <>
          "#{system_metrics_deleted} system metrics"
      )

      %{
        message_events: message_events_deleted,
        topology_snapshots: topology_snapshots_deleted,
        system_metrics: system_metrics_deleted
      }
    end)
  end

  ## Experiment Export

  @doc """
  Export a single experiment with complete analytics data.

  Delegates to `CorroPort.Analytics.Exporter` for format conversion.

  ## Formats
  - `:json` - Nested map structure with all experiment data
  - `:csv` - Flattened CSV format for spreadsheet analysis

  ## Options
  - `:include_raw_events` - Include all raw message events (default: true)
  - `:include_system_metrics` - Include detailed system metrics (default: true)

  ## Examples

      {:ok, data} = Analytics.export_experiment("exp123", :json)
      {:ok, csv} = Analytics.export_experiment("exp123", :csv)
  """
  defdelegate export_experiment(experiment_id, format \\ :json, opts \\ []),
    to: CorroPort.Analytics.Exporter

  @doc """
  Export multiple experiments as a comparison summary.

  Returns a summary table with key metrics for each experiment.

  ## Examples

      {:ok, comparison} = Analytics.export_comparison(["exp1", "exp2", "exp3"], :json)
      {:ok, csv} = Analytics.export_comparison(["exp1", "exp2"], :csv)
  """
  defdelegate export_comparison(experiment_ids, format \\ :json),
    to: CorroPort.Analytics.Exporter

  @doc """
  List all available experiments with basic information.

  Returns `{:ok, experiments}` where experiments is a list of maps with:
  - `experiment_id`
  - `message_count`
  - `send_count`
  - `ack_count`
  - `time_range`
  """
  defdelegate list_available_experiments(),
    to: CorroPort.Analytics.Exporter

end

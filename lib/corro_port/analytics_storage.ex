defmodule CorroPort.AnalyticsStorage do
  @moduledoc """
  GenServer wrapper around the Analytics context for managing experiment data.
  
  This module provides a GenServer interface to the Ecto-based Analytics context,
  allowing other parts of the application to interact with analytics data
  through a consistent API.
  
  Each node maintains its own SQLite database via Ecto to avoid burdening 
  the Corrosion cluster with analytics data.
  """

  use GenServer
  require Logger
  
  alias CorroPort.Analytics

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new topology snapshot for an experiment run.
  """
  def create_topology_snapshot(experiment_id, node_id, bootstrap_peers, transaction_size_bytes, transaction_frequency_ms) do
    Analytics.create_topology_snapshot(%{
      experiment_id: experiment_id,
      node_id: node_id,
      bootstrap_peers: bootstrap_peers,
      transaction_size_bytes: transaction_size_bytes,
      transaction_frequency_ms: transaction_frequency_ms
    })
  end

  @doc """
  Record a message timing event.
  """
  def record_message_event(message_id, experiment_id, originating_node, target_node, event_type, _timestamp, region \\ nil, transaction_size_hint \\ nil) do
    Analytics.record_message_event(%{
      message_id: message_id,
      experiment_id: experiment_id,
      originating_node: originating_node,
      target_node: target_node,
      event_type: event_type,
      region: region,
      transaction_size_hint: transaction_size_hint
    })
  end

  @doc """
  Record system metrics snapshot.
  """
  def record_system_metrics(experiment_id, node_id, cpu_percent, memory_mb, erlang_processes, corrosion_connections \\ nil, message_queue_length \\ nil) do
    Analytics.record_system_metrics(%{
      experiment_id: experiment_id,
      node_id: node_id,
      cpu_percent: cpu_percent,
      memory_mb: memory_mb,
      erlang_processes: erlang_processes,
      corrosion_connections: corrosion_connections,
      message_queue_length: message_queue_length
    })
  end

  @doc """
  Get topology snapshots for an experiment.
  """
  def get_topology_snapshots(experiment_id) do
    {:ok, Analytics.get_topology_snapshots(experiment_id)}
  end

  @doc """
  Get message events for an experiment with optional filters.
  """
  def get_message_events(experiment_id, opts \\ []) do
    {:ok, Analytics.get_message_events(experiment_id, opts)}
  end

  @doc """
  Get system metrics for an experiment with optional time range.
  """
  def get_system_metrics(experiment_id, opts \\ []) do
    {:ok, Analytics.get_system_metrics(experiment_id, opts)}
  end

  @doc """
  Get current experiment status and statistics.
  """
  def get_experiment_summary(experiment_id) do
    {:ok, Analytics.get_experiment_summary(experiment_id)}
  end
  
  @doc """
  Get message timing statistics for an experiment.
  """
  def get_message_timing_stats(experiment_id) do
    {:ok, Analytics.get_message_timing_stats(experiment_id)}
  end

  # GenServer Implementation

  def init(_opts) do
    Logger.info("AnalyticsStorage starting...")
    
    # The Analytics context and Repo handle database connections
    # This GenServer just provides a consistent interface
    {:ok, %{}}
  end

  def terminate(_reason, _state) do
    Logger.info("AnalyticsStorage shutting down")
    :ok
  end
end
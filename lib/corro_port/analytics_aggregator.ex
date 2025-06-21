defmodule CorroPort.AnalyticsAggregator do
  @moduledoc """
  Aggregates analytics data from multiple nodes in the cluster during experiments.
  
  This GenServer periodically polls all known cluster nodes to collect their
  analytics data and provides consolidated views for visualization and analysis.
  
  Key responsibilities:
  - Discover active cluster nodes via ClusterMembership
  - Poll each node's analytics data via HTTP API
  - Aggregate timing statistics across all nodes
  - Provide consolidated experiment summaries
  - Cache aggregated data for performance
  - Broadcast updates via PubSub for real-time dashboards
  
  Data Collection Strategy:
  - Each node maintains its own analytics database (Phase 1)
  - Aggregator polls nodes every 10 seconds during experiments
  - Aggregated data is cached locally with TTL
  - Real-time updates are pushed via Phoenix PubSub
  """

  use GenServer
  require Logger

  alias CorroPort.{ClusterMembership, LocalNode, Analytics}

  @default_collection_interval_ms 10_000  # Poll every 10 seconds
  @cache_ttl_ms 30_000  # Cache for 30 seconds
  @http_timeout_ms 5_000  # HTTP request timeout

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start aggregating data for an experiment across all cluster nodes.
  """
  def start_experiment_aggregation(experiment_id) do
    GenServer.call(__MODULE__, {:start_aggregation, experiment_id})
  end

  @doc """
  Stop aggregating data for the current experiment.
  """
  def stop_experiment_aggregation do
    GenServer.call(__MODULE__, :stop_aggregation)
  end

  @doc """
  Get aggregated experiment summary from all cluster nodes.
  Returns cached data if available, otherwise triggers fresh collection.
  """
  def get_cluster_experiment_summary(experiment_id) do
    GenServer.call(__MODULE__, {:get_cluster_summary, experiment_id}, 15_000)
  end

  @doc """
  Get aggregated message timing stats from all cluster nodes.
  """
  def get_cluster_timing_stats(experiment_id) do
    GenServer.call(__MODULE__, {:get_cluster_timing, experiment_id}, 15_000)
  end

  @doc """
  Get system metrics from all cluster nodes for an experiment.
  """
  def get_cluster_system_metrics(experiment_id) do
    GenServer.call(__MODULE__, {:get_cluster_metrics, experiment_id}, 15_000)
  end

  @doc """
  Force immediate collection from all nodes (bypasses cache).
  """
  def collect_now(experiment_id) do
    GenServer.cast(__MODULE__, {:collect_now, experiment_id})
  end

  @doc """
  Get list of nodes being aggregated from.
  """
  def get_active_nodes do
    GenServer.call(__MODULE__, :get_active_nodes)
  end

  @doc """
  Get comprehensive cluster analysis for an experiment.
  Includes timing distribution, node performance comparison, and error analysis.
  """
  def get_cluster_analysis(experiment_id) do
    GenServer.call(__MODULE__, {:get_cluster_analysis, experiment_id}, 15_000)
  end

  # GenServer Implementation

  def init(opts) do
    Logger.info("AnalyticsAggregator starting...")
    
    interval_ms = Keyword.get(opts, :interval_ms, @default_collection_interval_ms)
    
    state = %{
      experiment_id: nil,
      aggregating: false,
      interval_ms: interval_ms,
      timer_ref: nil,
      cache: %{},
      last_collection: nil,
      active_nodes: []
    }
    
    {:ok, state}
  end

  def handle_call({:start_aggregation, experiment_id}, _from, state) do
    Logger.info("AnalyticsAggregator: Starting aggregation for experiment #{experiment_id}")
    
    # Cancel existing timer if any
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    # Start periodic collection
    timer_ref = Process.send_after(self(), :collect_data, 1000)  # Start quickly
    
    new_state = %{state | 
      experiment_id: experiment_id,
      aggregating: true,
      timer_ref: timer_ref,
      cache: %{},  # Clear cache for new experiment
      active_nodes: discover_cluster_nodes()
    }
    
    # Trigger immediate collection
    collect_cluster_data(new_state)
    
    {:reply, :ok, new_state}
  end

  def handle_call(:stop_aggregation, _from, state) do
    Logger.info("AnalyticsAggregator: Stopping aggregation")
    
    # Cancel timer
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    new_state = %{state | 
      aggregating: false,
      timer_ref: nil,
      experiment_id: nil,
      cache: %{}
    }
    
    {:reply, :ok, new_state}
  end

  def handle_call({:get_cluster_summary, experiment_id}, _from, state) do
    case get_cached_or_collect(:summary, experiment_id, state) do
      {:ok, data, new_state} -> {:reply, {:ok, data}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_cluster_timing, experiment_id}, _from, state) do
    case get_cached_or_collect(:timing, experiment_id, state) do
      {:ok, data, new_state} -> {:reply, {:ok, data}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_cluster_metrics, experiment_id}, _from, state) do
    case get_cached_or_collect(:metrics, experiment_id, state) do
      {:ok, data, new_state} -> {:reply, {:ok, data}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_active_nodes, _from, state) do
    {:reply, state.active_nodes, state}
  end

  def handle_call({:get_cluster_analysis, experiment_id}, _from, state) do
    case generate_cluster_analysis(experiment_id, state) do
      {:ok, analysis} -> {:reply, {:ok, analysis}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_cast({:collect_now, experiment_id}, state) do
    if state.aggregating and state.experiment_id == experiment_id do
      collect_cluster_data(state)
    end
    {:noreply, state}
  end

  def handle_info(:collect_data, state) do
    if state.aggregating and state.experiment_id do
      collect_cluster_data(state)
      
      # Schedule next collection
      timer_ref = Process.send_after(self(), :collect_data, state.interval_ms)
      {:noreply, %{state | timer_ref: timer_ref}}
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  def terminate(_reason, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    Logger.info("AnalyticsAggregator shutting down")
    :ok
  end

  # Private Functions

  defp get_cached_or_collect(data_type, experiment_id, state) do
    cache_key = {data_type, experiment_id}
    now = System.monotonic_time(:millisecond)
    
    case Map.get(state.cache, cache_key) do
      {data, timestamp} when (now - timestamp) < @cache_ttl_ms ->
        # Return cached data
        {:ok, data, state}
      
      _ ->
        # Collect fresh data
        case collect_specific_data(data_type, experiment_id, state) do
          {:ok, data} ->
            new_cache = Map.put(state.cache, cache_key, {data, now})
            new_state = %{state | cache: new_cache}
            {:ok, data, new_state}
          
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp collect_cluster_data(state) do
    if state.experiment_id do
      # Update active nodes
      active_nodes = discover_cluster_nodes()
      
      # Collect all data types in parallel
      tasks = [
        Task.async(fn -> collect_specific_data(:summary, state.experiment_id, state) end),
        Task.async(fn -> collect_specific_data(:timing, state.experiment_id, state) end),
        Task.async(fn -> collect_specific_data(:metrics, state.experiment_id, state) end)
      ]
      
      # Wait for all tasks with timeout
      results = Task.yield_many(tasks, 12_000)
      
      # Process results and update cache
      now = System.monotonic_time(:millisecond)
      new_cache = Enum.reduce(results, state.cache, fn {task, result}, cache ->
        case result do
          {:ok, {:ok, data}} ->
            data_type = get_task_data_type(task)
            cache_key = {data_type, state.experiment_id}
            Map.put(cache, cache_key, {data, now})
          
          _ ->
            cache
        end
      end)
      
      # Broadcast updates if we have new data
      if map_size(new_cache) > map_size(state.cache) do
        broadcast_cluster_update(state.experiment_id, active_nodes)
      end
      
      Logger.debug("AnalyticsAggregator: Collected data from #{length(active_nodes)} nodes")
    end
  end

  defp collect_specific_data(:summary, experiment_id, state) do
    collect_from_all_nodes(experiment_id, state.active_nodes, fn node_info ->
      get_node_experiment_summary(node_info, experiment_id)
    end)
    |> case do
      {:ok, summaries} -> {:ok, aggregate_experiment_summaries(summaries)}
      error -> error
    end
  end

  defp collect_specific_data(:timing, experiment_id, state) do
    collect_from_all_nodes(experiment_id, state.active_nodes, fn node_info ->
      get_node_timing_stats(node_info, experiment_id)
    end)
    |> case do
      {:ok, timing_stats} -> {:ok, aggregate_timing_stats(timing_stats)}
      error -> error
    end
  end

  defp collect_specific_data(:metrics, experiment_id, state) do
    collect_from_all_nodes(experiment_id, state.active_nodes, fn node_info ->
      get_node_system_metrics(node_info, experiment_id)
    end)
    |> case do
      {:ok, metrics} -> {:ok, List.flatten(metrics)}
      error -> error
    end
  end

  defp collect_from_all_nodes(experiment_id, nodes, collector_fn) do
    local_node_id = LocalNode.get_node_id()
    
    # Collect from local node first (fast)
    local_result = if Enum.any?(nodes, &(&1.node_id == local_node_id)) do
      try do
        {:ok, collector_fn.(%{node_id: local_node_id, is_local: true})}
      catch
        _type, error ->
          Logger.warning("Failed to collect local data: #{inspect(error)}")
          {:error, "Local collection failed"}
      end
    else
      {:ok, []}
    end
    
    # Collect from remote nodes in parallel
    remote_nodes = Enum.reject(nodes, &(&1.node_id == local_node_id))
    
    remote_tasks = Enum.map(remote_nodes, fn node_info ->
      Task.async(fn ->
        try do
          collector_fn.(node_info)
        catch
          _type, error ->
            Logger.warn("Failed to collect from node #{node_info.node_id}: #{inspect(error)}")
            []
        end
      end)
    end)
    
    # Wait for remote results
    remote_results = Task.yield_many(remote_tasks, 8_000)
    |> Enum.map(fn {_task, result} ->
      case result do
        {:ok, data} -> data
        _ -> []
      end
    end)
    
    case local_result do
      {:ok, local_data} ->
        all_data = [local_data | remote_results]
        {:ok, all_data}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discover_cluster_nodes do
    try do
      # Get active members from ClusterMembership (fallback if module not available)
      members = try do
        CorroPort.ClusterMembership.get_active_members()
      rescue
        UndefinedFunctionError ->
          # Fallback to CLI member store
          CorroPort.CLIMemberStore.get_active_members()
      end
      
      # Convert to node info format
      Enum.map(members, fn member ->
        %{
          node_id: member.node_id,
          region: member.region,
          api_port: member.api_port,
          phoenix_port: calculate_phoenix_port(member),
          is_local: member.node_id == LocalNode.get_node_id()
        }
      end)
    catch
      _type, error ->
        Logger.warn("Failed to discover cluster nodes: #{inspect(error)}")
        # Fallback to local node only
        [%{
          node_id: LocalNode.get_node_id(),
          region: LocalNode.get_region(),
          is_local: true
        }]
    end
  end

  defp calculate_phoenix_port(member) do
    # Try to determine Phoenix port from member info
    # This might need adjustment based on your port mapping strategy
    cond do
      member.api_port && member.api_port > 4000 ->
        member.api_port  # Assume Phoenix and API are same port
      
      member.node_id =~ ~r/node(\d+)/ ->
        # Development pattern: node1 -> 4001, node2 -> 4002, etc.
        case Regex.run(~r/node(\d+)/, member.node_id) do
          [_, num_str] ->
            case Integer.parse(num_str) do
              {num, _} -> 4000 + num
              _ -> 4001
            end
          _ -> 4001
        end
      
      true ->
        4001  # Default fallback
    end
  end

  defp get_node_experiment_summary(%{is_local: true}, experiment_id) do
    # Local node - direct function call
    Analytics.get_experiment_summary(experiment_id)
  end

  defp get_node_experiment_summary(node_info, experiment_id) do
    # Remote node - HTTP API call
    url = "http://localhost:#{node_info.phoenix_port}/api/analytics/experiments/#{experiment_id}/summary"
    
    case Req.get(url, receive_timeout: @http_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: data}} ->
        atomize_keys(data)
      
      {:ok, %{status: status}} ->
        Logger.warn("HTTP #{status} from node #{node_info.node_id}")
        %{}
      
      {:error, reason} ->
        Logger.warn("HTTP error from node #{node_info.node_id}: #{inspect(reason)}")
        %{}
    end
  end

  defp get_node_timing_stats(%{is_local: true}, experiment_id) do
    Analytics.get_message_timing_stats(experiment_id)
  end

  defp get_node_timing_stats(node_info, experiment_id) do
    url = "http://localhost:#{node_info.phoenix_port}/api/analytics/experiments/#{experiment_id}/timing"
    
    case Req.get(url, receive_timeout: @http_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: data}} ->
        Enum.map(data, &atomize_keys/1)
      
      _ -> []
    end
  end

  defp get_node_system_metrics(%{is_local: true}, experiment_id) do
    Analytics.get_system_metrics(experiment_id)
  end

  defp get_node_system_metrics(node_info, experiment_id) do
    url = "http://localhost:#{node_info.phoenix_port}/api/analytics/experiments/#{experiment_id}/metrics"
    
    case Req.get(url, receive_timeout: @http_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: data}} ->
        Enum.map(data, &atomize_keys/1)
      
      _ -> []
    end
  end

  defp aggregate_experiment_summaries(summaries) do
    # Combine summaries from all nodes
    summaries
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        %{
          experiment_id: nil,
          topology_snapshots_count: 0,
          message_count: 0,
          send_count: 0,
          ack_count: 0,
          system_metrics_count: 0,
          node_count: 0
        }
      
      [first | rest] ->
        Enum.reduce(rest, first, fn summary, acc ->
          %{acc |
            topology_snapshots_count: acc.topology_snapshots_count + summary.topology_snapshots_count,
            message_count: acc.message_count + summary.message_count,
            send_count: acc.send_count + summary.send_count,
            ack_count: acc.ack_count + summary.ack_count,
            system_metrics_count: acc.system_metrics_count + summary.system_metrics_count
          }
        end)
        |> Map.put(:node_count, length(summaries))
    end
  end

  defp aggregate_timing_stats(timing_stats_lists) do
    # Combine timing stats from all nodes, grouping by message_id
    timing_stats_lists
    |> List.flatten()
    |> Enum.group_by(& &1.message_id)
    |> Enum.map(fn {message_id, stats} ->
      # Aggregate stats for the same message across nodes
      aggregate_message_timing(message_id, stats)
    end)
  end

  defp aggregate_message_timing(message_id, stats) do
    # Find the earliest send time and calculate aggregate ack info
    send_times = Enum.filter_map(stats, & &1.send_time, & &1.send_time)
    ack_counts = Enum.map(stats, & &1.ack_count)
    latencies = Enum.filter_map(stats, & &1.min_latency_ms, & &1.min_latency_ms)
    
    %{
      message_id: message_id,
      send_time: Enum.min(send_times, fn -> nil end),
      ack_count: Enum.sum(ack_counts),
      min_latency_ms: case latencies do
        [] -> nil
        list -> Enum.min(list)
      end,
      max_latency_ms: case latencies do
        [] -> nil
        list -> Enum.max(list)
      end,
      avg_latency_ms: case latencies do
        [] -> nil
        list -> Float.round(Enum.sum(list) / length(list), 2)
      end,
      node_count: length(stats)
    }
  end

  defp broadcast_cluster_update(experiment_id, active_nodes) do
    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      "analytics:#{experiment_id}",
      {:cluster_update, %{
        experiment_id: experiment_id,
        node_count: length(active_nodes),
        timestamp: DateTime.utc_now()
      }}
    )
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
  defp atomize_keys(other), do: other

  defp get_task_data_type(task) do
    # Helper to identify which data type a task was collecting
    # This is a simplified approach - in practice you might want to 
    # tag tasks with their purpose
    :summary  # Default fallback
  end

  defp generate_cluster_analysis(experiment_id, state) do
    try do
      # Collect all data types
      with {:ok, summary} <- collect_specific_data(:summary, experiment_id, state),
           {:ok, timing_stats} <- collect_specific_data(:timing, experiment_id, state),
           {:ok, system_metrics} <- collect_specific_data(:metrics, experiment_id, state) do
        
        analysis = %{
          experiment_id: experiment_id,
          cluster_summary: summary,
          timing_analysis: analyze_timing_distribution(timing_stats),
          node_performance: analyze_node_performance(system_metrics, timing_stats),
          message_flow: analyze_message_flow(timing_stats),
          error_analysis: analyze_errors(timing_stats),
          recommendations: generate_recommendations(timing_stats, system_metrics),
          generated_at: DateTime.utc_now()
        }
        
        {:ok, analysis}
      else
        error -> {:error, "Failed to collect data: #{inspect(error)}"}
      end
    rescue
      error -> {:error, "Analysis generation failed: #{inspect(error)}"}
    end
  end

  defp analyze_timing_distribution(timing_stats) do
    latencies = timing_stats
    |> Enum.filter(& &1.min_latency_ms)
    |> Enum.map(& &1.min_latency_ms)
    
    case latencies do
      [] ->
        %{
          total_messages: length(timing_stats),
          completed_messages: 0,
          min_latency: nil,
          max_latency: nil,
          avg_latency: nil,
          median_latency: nil,
          p95_latency: nil,
          distribution: []
        }
      
      _ ->
        sorted_latencies = Enum.sort(latencies)
        count = length(sorted_latencies)
        
        %{
          total_messages: length(timing_stats),
          completed_messages: count,
          min_latency: Enum.min(sorted_latencies),
          max_latency: Enum.max(sorted_latencies),
          avg_latency: Float.round(Enum.sum(sorted_latencies) / count, 2),
          median_latency: calculate_percentile(sorted_latencies, 50),
          p95_latency: calculate_percentile(sorted_latencies, 95),
          distribution: create_latency_histogram(sorted_latencies)
        }
    end
  end

  defp analyze_node_performance(system_metrics, timing_stats) do
    # Group metrics by node
    node_metrics = Enum.group_by(system_metrics, & &1.node_id)
    
    # Analyze each node's performance
    Enum.map(node_metrics, fn {node_id, metrics} ->
      latest_metric = Enum.max_by(metrics, & &1.inserted_at, DateTime)
      
      # Find messages originating from this node (handle both string and map access)
      node_messages = Enum.filter(timing_stats, fn stat ->
        originating_node = case stat do
          %{originating_node: node} -> node
          _ -> nil
        end
        originating_node == node_id
      end)
      node_latencies = Enum.filter_map(node_messages, & &1.min_latency_ms, & &1.min_latency_ms)
      
      %{
        node_id: node_id,
        memory_mb: latest_metric.memory_mb,
        cpu_percent: latest_metric.cpu_percent,
        erlang_processes: latest_metric.erlang_processes,
        messages_sent: length(node_messages),
        avg_message_latency: case node_latencies do
          [] -> nil
          list -> Float.round(Enum.sum(list) / length(list), 2)
        end,
        performance_score: calculate_performance_score(latest_metric, node_latencies)
      }
    end)
    |> Enum.sort_by(& &1.performance_score, :desc)
  end

  defp analyze_message_flow(timing_stats) do
    # Analyze message flow patterns between nodes
    flows = timing_stats
    |> Enum.group_by(fn stat ->
      originating = case stat do
        %{originating_node: node} -> node
        _ -> "unknown"
      end
      target = case stat do
        %{target_node: node} -> node
        _ -> "unknown"
      end
      {originating, target}
    end)
    |> Enum.map(fn {{from, to}, messages} ->
      latencies = Enum.filter_map(messages, & &1.min_latency_ms, & &1.min_latency_ms)
      
      %{
        from_node: from,
        to_node: to,
        message_count: length(messages),
        success_rate: if(length(messages) > 0, do: length(latencies) / length(messages), else: 0),
        avg_latency: case latencies do
          [] -> nil
          list -> Float.round(Enum.sum(list) / length(list), 2)
        end
      }
    end)
    |> Enum.sort_by(& &1.message_count, :desc)
    
    %{
      flows: flows,
      total_flows: length(flows),
      most_active_flow: Enum.max_by(flows, & &1.message_count, fn -> nil end),
      slowest_flow: Enum.max_by(flows, & &1.avg_latency || 0, fn -> nil end)
    }
  end

  defp analyze_errors(timing_stats) do
    total_messages = length(timing_stats)
    failed_messages = Enum.filter(timing_stats, &is_nil(&1.min_latency_ms))
    
    %{
      total_messages: total_messages,
      failed_messages: length(failed_messages),
      success_rate: if(total_messages > 0, do: (total_messages - length(failed_messages)) / total_messages, else: 0),
      failure_patterns: analyze_failure_patterns(failed_messages)
    }
  end

  defp analyze_failure_patterns(failed_messages) do
    failed_messages
    |> Enum.group_by(fn stat ->
      case stat do
        %{originating_node: node} -> node
        _ -> "unknown"
      end
    end)
    |> Enum.map(fn {node, failures} ->
      %{node_id: node, failure_count: length(failures)}
    end)
    |> Enum.sort_by(& &1.failure_count, :desc)
  end

  defp generate_recommendations(timing_stats, system_metrics) do
    recommendations = []
    
    # High latency recommendation
    avg_latencies = timing_stats
    |> Enum.filter(& &1.min_latency_ms)
    |> Enum.map(& &1.min_latency_ms)
    
    recommendations = if length(avg_latencies) > 0 do
      avg = Enum.sum(avg_latencies) / length(avg_latencies)
      if avg > 1000 do
        [%{
          type: :performance,
          priority: :high,
          message: "Average latency #{Float.round(avg, 1)}ms is high. Consider network optimization."
        } | recommendations]
      else
        recommendations
      end
    else
      recommendations
    end
    
    # Memory recommendation
    high_memory_nodes = system_metrics
    |> Enum.filter(&(&1.memory_mb > 1000))
    |> Enum.map(& &1.node_id)
    |> Enum.uniq()
    
    recommendations = if length(high_memory_nodes) > 0 do
      [%{
        type: :resource,
        priority: :medium,
        message: "High memory usage detected on nodes: #{Enum.join(high_memory_nodes, ", ")}"
      } | recommendations]
    else
      recommendations
    end
    
    # Success rate recommendation
    total = length(timing_stats)
    successful = length(Enum.filter(timing_stats, & &1.min_latency_ms))
    success_rate = if total > 0, do: successful / total, else: 0
    
    recommendations = if success_rate < 0.95 do
      [%{
        type: :reliability,
        priority: :high,
        message: "Message success rate #{Float.round(success_rate * 100, 1)}% is below 95%. Investigate network reliability."
      } | recommendations]
    else
      recommendations
    end
    
    recommendations
  end

  defp calculate_percentile(sorted_list, percentile) do
    count = length(sorted_list)
    index = Float.round(count * percentile / 100) |> trunc()
    index = max(0, min(index - 1, count - 1))
    Enum.at(sorted_list, index)
  end

  defp create_latency_histogram(latencies) do
    # Create 10 buckets for latency distribution
    min_lat = Enum.min(latencies)
    max_lat = Enum.max(latencies)
    bucket_size = max(1, (max_lat - min_lat) / 10)
    
    buckets = 0..9
    |> Enum.map(fn i ->
      bucket_min = min_lat + i * bucket_size
      bucket_max = min_lat + (i + 1) * bucket_size
      
      count = Enum.count(latencies, fn lat ->
        lat >= bucket_min and lat < bucket_max
      end)
      
      %{
        range: "#{Float.round(bucket_min, 1)}-#{Float.round(bucket_max, 1)}ms",
        count: count
      }
    end)
    
    buckets
  end

  defp calculate_performance_score(metric, latencies) do
    # Simple performance scoring based on resource usage and latency
    memory_score = max(0, 100 - (metric.memory_mb / 10))  # Lower memory is better
    process_score = max(0, 100 - (metric.erlang_processes / 100))  # Fewer processes generally better
    
    latency_score = case latencies do
      [] -> 50  # Neutral score for no latency data
      list -> 
        avg_latency = Enum.sum(list) / length(list)
        max(0, 100 - avg_latency / 10)  # Lower latency is better
    end
    
    # Weighted average
    Float.round((memory_score * 0.3 + process_score * 0.2 + latency_score * 0.5), 1)
  end
end
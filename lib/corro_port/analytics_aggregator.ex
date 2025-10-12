defmodule CorroPort.AnalyticsAggregator do
  @moduledoc """
  Coordinates analytics collection for experiment dashboards.

  The GenServer schedules periodic refreshes, caches summaries/timing/metrics
  with a short TTL, and broadcasts PubSub updates so LiveViews can refresh
  without polling. At the moment all collections are local-first – we call into
  the `CorroPort.Analytics` context directly and reuse the cached results for a
  few seconds. The module still carries helper functions for multi-node polling
  (via `CorroPort.CLIClusterData` discovery and HTTP requests), but those paths
  are intentionally dormant until the remote Corrosion agents can expose the
  required APIs without 500s.

  Key responsibilities:
  - start/stop experiment aggregation cycles on demand
  - keep a short-lived cache per experiment for summary, timing, and metric data
  - broadcast `analytics:*` PubSub messages after fresh collections
  - surface discovered node metadata for future multi-node analytics work
  """

  use GenServer
  require Logger

  alias CorroPort.{ClusterMembership, LocalNode, Analytics}
  alias CorroPort.Analytics.Queries
  alias CorroPort.{MessagesAPI, PubSubMessageSender}

  # Poll every 10 seconds
  @default_collection_interval_ms 10_000
  # Cache for 30 seconds
  @cache_ttl_ms 30_000
  # Wait before final collection after sending last message
  @finalize_delay_ms 3_000
  # HTTP request timeout
  @http_timeout_ms 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start aggregating data for an experiment across all cluster nodes.

  Options:
  - `:message_count` - Number of messages to send automatically (default: 0, disabled)
  - `:message_interval_ms` - Interval between messages in milliseconds (default: 1000)
  - `:transport_mode` - Message transport: `:corrosion` (default) or `:pubsub`
  """
  def start_experiment_aggregation(experiment_id, opts \\ []) do
    GenServer.call(__MODULE__, {:start_aggregation, experiment_id, opts})
  end

  @doc """
  Get the current running experiment ID, if any.
  """
  def get_current_experiment_id do
    GenServer.call(__MODULE__, :get_current_experiment_id)
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
      active_nodes: [],
      # Message sending configuration
      message_config: %{
        enabled: false,
        total_count: 0,
        sent_count: 0,
        interval_ms: 1000,
        transport_mode: :corrosion
      },
      message_timer_ref: nil,
      finalize_timer_ref: nil
    }

    {:ok, state}
  end

  def handle_call({:start_aggregation, experiment_id, opts}, _from, state) do
    Logger.info("AnalyticsAggregator: Starting aggregation for experiment #{experiment_id}")

    # Cancel existing timers if any
    cancel_timer(state.timer_ref)
    cancel_timer(state.message_timer_ref)
    cancel_timer(state.finalize_timer_ref)

    # Set experiment ID in SystemMetrics and AckTracker so message operations get recorded
    CorroPort.SystemMetrics.set_experiment_id(experiment_id)
    CorroPort.AckTracker.set_experiment_id(experiment_id)

    # Configure message sending
    message_count = Keyword.get(opts, :message_count, 0)
    message_interval_ms = Keyword.get(opts, :message_interval_ms, 1000)
    transport_mode = Keyword.get(opts, :transport_mode, :corrosion)

    message_config = %{
      enabled: message_count > 0,
      total_count: message_count,
      sent_count: 0,
      interval_ms: message_interval_ms,
      transport_mode: transport_mode
    }

    # Start message sending if configured
    message_timer_ref =
      if message_config.enabled do
        Logger.info("AnalyticsAggregator: Will send #{message_count} messages at #{message_interval_ms}ms intervals via #{transport_mode}")
        Process.send_after(self(), :send_message, 500)
      else
        nil
      end

    # Start periodic collection
    # Start quickly
    timer_ref = Process.send_after(self(), :collect_data, 1000)

    new_state = %{
      state
      | experiment_id: experiment_id,
        aggregating: true,
        timer_ref: timer_ref,
        message_config: message_config,
        message_timer_ref: message_timer_ref,
        # Clear cache for new experiment
        cache: %{},
        active_nodes: discover_cluster_nodes(),
        finalize_timer_ref: nil
    }

    # Trigger immediate collection
    updated_state = collect_cluster_data(new_state)

    {:reply, :ok, updated_state}
  end

  def handle_call(:stop_aggregation, _from, state) do
    Logger.info("AnalyticsAggregator: Stopping aggregation")

    {:reply, :ok, stop_experiment(state)}
  end

  def handle_call(:get_current_experiment_id, _from, state) do
    {:reply, state.experiment_id, state}
  end

  def handle_call({:get_cluster_summary, experiment_id}, _from, state) do
    case get_cached_or_collect(:summary, experiment_id, state) do
      {:ok, data, new_state} ->
        summary = normalize_summary(data)
        # CLIClusterData excludes local node, so add 1 for total cluster size
        # This gives us the complete cluster size for display
        total_cluster_nodes = length(new_state.active_nodes) + 1
        updated_data = Map.put(summary, :node_count, total_cluster_nodes)
        {:reply, {:ok, updated_data}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
    new_state =
      if state.aggregating and state.experiment_id == experiment_id do
        collect_cluster_data(state)
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_info(:collect_data, state) do
    if state.aggregating and state.experiment_id do
      state = collect_cluster_data(state)

      # Schedule next collection
      timer_ref = Process.send_after(self(), :collect_data, state.interval_ms)
      {:noreply, %{state | timer_ref: timer_ref}}
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  def handle_info({:finalize_experiment, experiment_id}, state) do
    if state.experiment_id == experiment_id do
      Logger.info("AnalyticsAggregator: Performing final collection for experiment #{experiment_id}")
      state = collect_cluster_data(state)
      {:noreply, stop_experiment(%{state | finalize_timer_ref: nil})}
    else
      {:noreply, state}
    end
  end

  def handle_info(:send_message, state) do
    if state.aggregating and state.message_config.enabled do
      sent_count = state.message_config.sent_count
      total_count = state.message_config.total_count

      if sent_count < total_count do
        # Send the message using the configured transport
        message_content = "Experiment #{state.experiment_id} message #{sent_count + 1}/#{total_count}"
        transport_mode = state.message_config.transport_mode

        result =
          case transport_mode do
            :pubsub ->
              PubSubMessageSender.send_and_track_message(message_content,
                experiment_id: state.experiment_id
              )

            _ ->
              MessagesAPI.send_and_track_message(message_content,
                experiment_id: state.experiment_id
              )
          end

        case result do
          {:ok, _message_data} ->
            Logger.info("AnalyticsAggregator: Sent message #{sent_count + 1}/#{total_count} via #{transport_mode}")

          {:error, reason} ->
            Logger.warning("AnalyticsAggregator: Failed to send message via #{transport_mode}: #{inspect(reason)}")
        end

        # Update sent count
        new_sent_count = sent_count + 1
        new_message_config = %{state.message_config | sent_count: new_sent_count}

        # Broadcast progress update
        broadcast_message_progress(state.experiment_id, new_sent_count, total_count)

        # Schedule next message if more to send, otherwise stop experiment
        if new_sent_count < total_count do
          message_timer_ref = Process.send_after(self(), :send_message, state.message_config.interval_ms)
          {:noreply, %{state | message_config: new_message_config, message_timer_ref: message_timer_ref}}
        else
          Logger.info(
            "AnalyticsAggregator: Completed sending all #{total_count} messages - scheduling final collection"
          )

          finalize_timer_ref =
            Process.send_after(self(), {:finalize_experiment, state.experiment_id}, @finalize_delay_ms)

          new_state = %{
            state
            | message_config: %{state.message_config | sent_count: new_sent_count, enabled: false},
              message_timer_ref: nil,
              finalize_timer_ref: finalize_timer_ref
          }

          {:noreply, new_state}
        end
      else
        {:noreply, %{state | message_timer_ref: nil}}
      end
    else
      {:noreply, %{state | message_timer_ref: nil}}
    end
  end

  def terminate(_reason, state) do
    cancel_timer(Map.get(state, :timer_ref))
    cancel_timer(Map.get(state, :message_timer_ref))
    cancel_timer(Map.get(state, :finalize_timer_ref))

    Logger.info("AnalyticsAggregator shutting down")
    :ok
  end

  # Private Functions

  defp get_cached_or_collect(data_type, experiment_id, state) do
    cache_key = {data_type, experiment_id}
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, cache_key) do
      {data, timestamp} when now - timestamp < @cache_ttl_ms ->
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

      Enum.each(results, fn {task, res} ->
        if res == nil do
          Task.shutdown(task, :brutal_kill)
        end
      end)

      # Process results and update cache
      now = System.monotonic_time(:millisecond)

      {new_cache, updated?} =
        Enum.reduce(results, {state.cache, false}, fn {task, result}, {cache, changed?} ->
          case result do
            {:ok, {:ok, data}} ->
              data_type = get_task_data_type(task)
              cache_key = {data_type, state.experiment_id}
              updated_cache = Map.put(cache, cache_key, {data, now})
              {updated_cache, true}

            _ ->
              {cache, changed?}
          end
        end)

      if updated? do
        broadcast_cluster_update(state.experiment_id, active_nodes)
      end

      Logger.debug("AnalyticsAggregator: Collected data from #{length(active_nodes)} nodes")

      %{
        state
        | cache: new_cache,
          active_nodes: active_nodes,
          last_collection: DateTime.utc_now()
      }
    else
      state
    end
  end

  defp stop_experiment(state) do
    cancel_timer(state.timer_ref)
    cancel_timer(state.message_timer_ref)
    cancel_timer(state.finalize_timer_ref)

    if state.experiment_id do
      CorroPort.SystemMetrics.set_experiment_id(nil)
      CorroPort.AckTracker.set_experiment_id(nil)

      Phoenix.PubSub.broadcast(
        CorroPort.PubSub,
        "analytics:#{state.experiment_id}",
        {:experiment_stopped, state.experiment_id}
      )
    end

    %{
      state
      | aggregating: false,
        timer_ref: nil,
        message_timer_ref: nil,
        finalize_timer_ref: nil,
        experiment_id: nil,
        cache: %{},
        message_config: %{enabled: false, total_count: 0, sent_count: 0, interval_ms: 1000, transport_mode: :corrosion}
    }
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp collect_specific_data(:summary, experiment_id, _state) do
    # Only query local node for now - avoid 500s from remote nodes
    local_node = get_local_node_info()
    summary = get_node_experiment_summary(local_node, experiment_id)
    {:ok, summary}
  end

  defp collect_specific_data(:timing, experiment_id, _state) do
    # Only query local node for now - avoid 500s from remote nodes
    local_node = get_local_node_info()
    timing_stats = get_node_timing_stats(local_node, experiment_id)
    {:ok, timing_stats}
  end

  defp collect_specific_data(:metrics, experiment_id, _state) do
    # Only query local node for now - avoid 500s from remote nodes
    local_node = get_local_node_info()
    metrics = get_node_system_metrics(local_node, experiment_id)
    {:ok, metrics}
  end

  defp get_local_node_info do
    local_node_id = LocalNode.get_node_id()
    local_phoenix_port = calculate_phoenix_port(%{node_id: local_node_id, api_port: nil})

    %{
      node_id: local_node_id,
      region: LocalNode.get_region(),
      phoenix_port: local_phoenix_port,
      is_local: true
    }
  end

  # Legacy function for when we want to collect from all nodes again
  defp collect_specific_data_from_all_nodes(:summary, experiment_id, state) do
    collect_from_all_nodes(experiment_id, state.active_nodes, fn node_info ->
      get_node_experiment_summary(node_info, experiment_id)
    end)
    |> case do
      {:ok, summaries} -> {:ok, aggregate_experiment_summaries(summaries)}
      error -> error
    end
  end

  defp collect_specific_data_from_all_nodes(:timing, experiment_id, state) do
    collect_from_all_nodes(experiment_id, state.active_nodes, fn node_info ->
      get_node_timing_stats(node_info, experiment_id)
    end)
    |> case do
      {:ok, timing_stats} -> {:ok, aggregate_timing_stats(timing_stats)}
      error -> error
    end
  end

  defp collect_specific_data_from_all_nodes(:metrics, experiment_id, state) do
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
    local_result =
      if Enum.any?(nodes, &(&1.node_id == local_node_id)) do
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

    remote_tasks =
      Enum.map(remote_nodes, fn node_info ->
        Task.async(fn ->
          try do
            collector_fn.(node_info)
          catch
            _type, error ->
              Logger.warning(
                "Failed to collect from node #{node_info.node_id}: #{inspect(error)}"
              )

              []
          end
        end)
      end)

    # Wait for remote results
    remote_results =
      Task.yield_many(remote_tasks, 8_000)
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
      # Get CLI members from CLIClusterData
      cli_data = CorroPort.CLIClusterData.get_cli_data()

      # Extract members from the CLI data structure
      members =
        case cli_data.members do
          {:ok, member_list} ->
            member_list

          {:error, reason} ->
            Logger.warning(
              "AnalyticsAggregator: Failed to get members from CLIClusterData: #{inspect(reason)}"
            )

            []
        end

      Logger.info("AnalyticsAggregator: Discovered #{length(members)} cluster nodes")

      # Convert to node info format
      nodes =
        Enum.map(members, fn member ->
          node_id = CorroPort.AckTracker.member_to_node_id(member)
          region = CorroPort.NodeNaming.extract_region_from_node_id(node_id)

          %{
            node_id: node_id,
            region: region,
            # Not available in member structure, will be calculated
            api_port: nil,
            phoenix_port: calculate_phoenix_port(member),
            is_local: node_id == LocalNode.get_node_id()
          }
        end)
        # Filter out nodes with nil node_id
        |> Enum.reject(fn node -> is_nil(node.node_id) end)

      Logger.debug("AnalyticsAggregator: Node details: #{inspect(nodes)}")
      nodes
    catch
      _type, error ->
        Logger.warning("Failed to discover cluster nodes: #{inspect(error)}")
        # Fallback to local node only
        local_node_id = LocalNode.get_node_id()
        local_phoenix_port = calculate_phoenix_port(%{node_id: local_node_id, api_port: nil})

        [
          %{
            node_id: local_node_id,
            region: LocalNode.get_region(),
            phoenix_port: local_phoenix_port,
            is_local: true
          }
        ]
    end
  end

  defp calculate_phoenix_port(member) do
    # Extract node_id from member to determine Phoenix port
    node_id = CorroPort.AckTracker.member_to_node_id(member)

    cond do
      # Development pattern: node1 -> 4001, node2 -> 4002, etc.
      is_binary(node_id) and node_id =~ ~r/node(\d+)/ ->
        case Regex.run(~r/node(\d+)/, node_id) do
          [_, num_str] ->
            case Integer.parse(num_str) do
              {num, _} -> 4000 + num
              _ -> 4001
            end

          _ ->
            4001
        end

      true ->
        # Default fallback
        4001
    end
  end

  defp get_node_experiment_summary(%{is_local: true}, experiment_id) do
    # Local node - direct function call
    Analytics.get_experiment_summary(experiment_id)
  end

  defp get_node_experiment_summary(node_info, experiment_id) do
    # Remote node - HTTP API call
    url =
      "http://localhost:#{node_info.phoenix_port}/api/analytics/experiments/#{experiment_id}/summary"

    case Req.get(url, receive_timeout: @http_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: data}} ->
        atomize_keys(data)

      {:ok, %{status: status}} ->
        Logger.warning("HTTP #{status} from node #{node_info.node_id}")
        default_empty_summary()

      {:error, reason} ->
        Logger.warning("HTTP error from node #{node_info.node_id}: #{inspect(reason)}")
        default_empty_summary()
    end
  end

  defp default_empty_summary do
    %{
      experiment_id: nil,
      topology_snapshots_count: 0,
      message_count: 0,
      send_count: 0,
      ack_count: 0,
      system_metrics_count: 0,
      node_count: 0
    }
  end

  defp normalize_summary(%{} = summary), do: summary
  defp normalize_summary(_), do: default_empty_summary()

  defp get_node_timing_stats(%{is_local: true}, experiment_id) do
    Queries.get_message_timing_stats(experiment_id)
  end

  defp get_node_timing_stats(node_info, experiment_id) do
    url =
      "http://localhost:#{node_info.phoenix_port}/api/analytics/experiments/#{experiment_id}/timing"

    case Req.get(url, receive_timeout: @http_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: data}} ->
        Enum.map(data, &atomize_keys/1)

      _ ->
        []
    end
  end

  defp get_node_system_metrics(%{is_local: true}, experiment_id) do
    Analytics.get_system_metrics(experiment_id)
  end

  defp get_node_system_metrics(node_info, experiment_id) do
    url =
      "http://localhost:#{node_info.phoenix_port}/api/analytics/experiments/#{experiment_id}/metrics"

    case Req.get(url, receive_timeout: @http_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: data}} ->
        Enum.map(data, &atomize_keys/1)

      _ ->
        []
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
          %{
            acc
            | topology_snapshots_count:
                acc.topology_snapshots_count + summary.topology_snapshots_count,
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
    send_times = for entry <- stats, entry.send_time, do: entry.send_time
    ack_counts = Enum.map(stats, & &1.ack_count)
    latencies = for entry <- stats, entry.min_latency_ms, do: entry.min_latency_ms

    %{
      message_id: message_id,
      send_time: Enum.min(send_times, fn -> nil end),
      ack_count: Enum.sum(ack_counts),
      min_latency_ms:
        case latencies do
          [] -> nil
          list -> Enum.min(list)
        end,
      max_latency_ms:
        case latencies do
          [] -> nil
          list -> Enum.max(list)
        end,
      avg_latency_ms:
        case latencies do
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
      {:cluster_update,
       %{
         experiment_id: experiment_id,
         node_count: length(active_nodes),
         timestamp: DateTime.utc_now()
       }}
    )
  end

  defp broadcast_message_progress(experiment_id, sent_count, total_count) do
    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      "analytics:#{experiment_id}",
      {:message_progress,
       %{
         experiment_id: experiment_id,
         sent_count: sent_count,
         total_count: total_count,
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
    # Default fallback
    :summary
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
    latencies =
      timing_stats
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
      node_messages =
        Enum.filter(timing_stats, fn stat ->
          originating_node =
            case stat do
              %{originating_node: node} -> node
              _ -> nil
            end

          originating_node == node_id
        end)

      node_latencies = for msg <- node_messages, msg.min_latency_ms, do: msg.min_latency_ms

      %{
        node_id: node_id,
        memory_mb: latest_metric.memory_mb,
        cpu_percent: latest_metric.cpu_percent,
        erlang_processes: latest_metric.erlang_processes,
        messages_sent: length(node_messages),
        avg_message_latency:
          case node_latencies do
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
    flows =
      timing_stats
      |> Enum.group_by(fn stat ->
        originating =
          case stat do
            %{originating_node: node} -> node
            _ -> "unknown"
          end

        target =
          case stat do
            %{target_node: node} -> node
            _ -> "unknown"
          end

        {originating, target}
      end)
      |> Enum.map(fn {{from, to}, messages} ->
        latencies = for msg <- messages, msg.min_latency_ms, do: msg.min_latency_ms

        %{
          from_node: from,
          to_node: to,
          message_count: length(messages),
          success_rate:
            if(length(messages) > 0, do: length(latencies) / length(messages), else: 0),
          avg_latency:
            case latencies do
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
      slowest_flow: Enum.max_by(flows, &(&1.avg_latency || 0), fn -> nil end)
    }
  end

  defp analyze_errors(timing_stats) do
    total_messages = length(timing_stats)
    failed_messages = Enum.filter(timing_stats, &is_nil(&1.min_latency_ms))

    %{
      total_messages: total_messages,
      failed_messages: length(failed_messages),
      success_rate:
        if(total_messages > 0,
          do: (total_messages - length(failed_messages)) / total_messages,
          else: 0
        ),
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
    avg_latencies =
      timing_stats
      |> Enum.filter(& &1.min_latency_ms)
      |> Enum.map(& &1.min_latency_ms)

    recommendations =
      if length(avg_latencies) > 0 do
        avg = Enum.sum(avg_latencies) / length(avg_latencies)

        if avg > 1000 do
          [
            %{
              type: :performance,
              priority: :high,
              message:
                "Average latency #{Float.round(avg, 1)}ms is high. Consider network optimization."
            }
            | recommendations
          ]
        else
          recommendations
        end
      else
        recommendations
      end

    # Memory recommendation
    high_memory_nodes =
      system_metrics
      |> Enum.filter(&(&1.memory_mb > 1000))
      |> Enum.map(& &1.node_id)
      |> Enum.uniq()

    recommendations =
      if length(high_memory_nodes) > 0 do
        [
          %{
            type: :resource,
            priority: :medium,
            message: "High memory usage detected on nodes: #{Enum.join(high_memory_nodes, ", ")}"
          }
          | recommendations
        ]
      else
        recommendations
      end

    # Success rate recommendation
    total = length(timing_stats)
    successful = length(Enum.filter(timing_stats, & &1.min_latency_ms))
    success_rate = if total > 0, do: successful / total, else: 0

    recommendations =
      if success_rate < 0.95 do
        [
          %{
            type: :reliability,
            priority: :high,
            message:
              "Message success rate #{Float.round(success_rate * 100, 1)}% is below 95%. Investigate network reliability."
          }
          | recommendations
        ]
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

    buckets =
      0..9
      |> Enum.map(fn i ->
        bucket_min = min_lat + i * bucket_size
        bucket_max = min_lat + (i + 1) * bucket_size

        count =
          Enum.count(latencies, fn lat ->
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
    # Lower memory is better
    memory_score = max(0, 100 - metric.memory_mb / 10)
    # Fewer processes generally better
    process_score = max(0, 100 - metric.erlang_processes / 100)

    latency_score =
      case latencies do
        # Neutral score for no latency data
        [] ->
          50

        list ->
          avg_latency = Enum.sum(list) / length(list)
          # Lower latency is better
          max(0, 100 - avg_latency / 10)
      end

    # Weighted average
    Float.round(memory_score * 0.3 + process_score * 0.2 + latency_score * 0.5, 1)
  end
end

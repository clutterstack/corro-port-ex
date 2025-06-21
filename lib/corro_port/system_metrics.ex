defmodule CorroPort.SystemMetrics do
  @moduledoc """
  Monitors system performance metrics including CPU, memory, and Erlang VM statistics.
  
  Collects metrics at configurable intervals and stores them via AnalyticsStorage
  for correlation with message propagation performance during experiments.
  
  Metrics collected:
  - CPU usage percentage (via :observer_backend.sys_info/0)
  - Memory usage in MB (via :erlang.memory/0)
  - Erlang process count (via :erlang.system_info/1)
  - Corrosion connection health
  - Message queue lengths
  """

  use GenServer
  require Logger

  @default_interval_ms 5_000  # Collect metrics every 5 seconds
  @cpu_sample_interval_ms 1_000  # CPU sampling interval

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Set the current experiment ID for metrics collection.
  """
  def set_experiment_id(experiment_id) do
    GenServer.call(__MODULE__, {:set_experiment_id, experiment_id})
  end

  @doc """
  Get current experiment ID.
  """
  def get_experiment_id do
    GenServer.call(__MODULE__, :get_experiment_id)
  end

  @doc """
  Start collecting metrics for an experiment.
  """
  def start_collection(experiment_id) do
    GenServer.call(__MODULE__, {:start_collection, experiment_id})
  end

  @doc """
  Stop collecting metrics.
  """
  def stop_collection do
    GenServer.call(__MODULE__, :stop_collection)
  end

  @doc """
  Get current system metrics snapshot (without storing).
  """
  def get_current_metrics do
    GenServer.call(__MODULE__, :get_current_metrics)
  end

  @doc """
  Force a metrics collection now.
  """
  def collect_now do
    GenServer.cast(__MODULE__, :collect_now)
  end

  # GenServer Implementation

  def init(opts) do
    Logger.info("SystemMetrics starting...")
    
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    
    state = %{
      experiment_id: nil,
      collecting: false,
      interval_ms: interval_ms,
      timer_ref: nil,
      node_id: CorroPort.LocalNode.get_node_id()
    }
    
    {:ok, state}
  end

  def handle_call({:set_experiment_id, experiment_id}, _from, state) do
    Logger.info("SystemMetrics: Set experiment ID to #{experiment_id}")
    {:reply, :ok, %{state | experiment_id: experiment_id}}
  end

  def handle_call(:get_experiment_id, _from, state) do
    {:reply, state.experiment_id, state}
  end

  def handle_call({:start_collection, experiment_id}, _from, state) do
    Logger.info("SystemMetrics: Starting collection for experiment #{experiment_id}")
    
    # Cancel existing timer if any
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    # Start periodic collection
    timer_ref = Process.send_after(self(), :collect_metrics, state.interval_ms)
    
    new_state = %{state | 
      experiment_id: experiment_id,
      collecting: true,
      timer_ref: timer_ref
    }
    
    # Collect initial metrics
    collect_metrics(new_state)
    
    {:reply, :ok, new_state}
  end

  def handle_call(:stop_collection, _from, state) do
    Logger.info("SystemMetrics: Stopping collection")
    
    # Cancel timer
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    new_state = %{state | 
      collecting: false,
      timer_ref: nil,
      experiment_id: nil
    }
    
    {:reply, :ok, new_state}
  end

  def handle_call(:get_current_metrics, _from, state) do
    metrics = collect_current_metrics()
    {:reply, metrics, state}
  end

  def handle_cast(:collect_now, state) do
    if state.collecting and state.experiment_id do
      collect_metrics(state)
    end
    {:noreply, state}
  end

  def handle_info(:collect_metrics, state) do
    if state.collecting and state.experiment_id do
      collect_metrics(state)
      
      # Schedule next collection
      timer_ref = Process.send_after(self(), :collect_metrics, state.interval_ms)
      {:noreply, %{state | timer_ref: timer_ref}}
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  def terminate(_reason, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    Logger.info("SystemMetrics shutting down")
    :ok
  end

  # Private Functions

  defp collect_metrics(state) do
    if state.experiment_id do
      metrics = collect_current_metrics()
      
      # Store via AnalyticsStorage
      CorroPort.AnalyticsStorage.record_system_metrics(
        state.experiment_id,
        state.node_id,
        metrics.cpu_percent,
        metrics.memory_mb,
        metrics.erlang_processes,
        metrics.corrosion_connections,
        metrics.message_queue_length
      )
      
      Logger.debug("Collected metrics for experiment #{state.experiment_id}: CPU=#{metrics.cpu_percent}%, Memory=#{metrics.memory_mb}MB, Processes=#{metrics.erlang_processes}")
    end
  end

  defp collect_current_metrics do
    # Collect various system metrics
    memory_info = collect_memory_metrics()
    cpu_percent = collect_cpu_metrics()
    process_count = collect_process_metrics()
    corrosion_connections = collect_corrosion_connection_metrics()
    message_queue_length = collect_message_queue_metrics()
    
    %{
      cpu_percent: cpu_percent,
      memory_mb: memory_info.total_mb,
      erlang_processes: process_count,
      corrosion_connections: corrosion_connections,
      message_queue_length: message_queue_length,
      memory_breakdown: memory_info.breakdown
    }
  end

  defp collect_memory_metrics do
    memory = :erlang.memory()
    
    total_bytes = Keyword.get(memory, :total, 0)
    processes_bytes = Keyword.get(memory, :processes, 0)
    system_bytes = Keyword.get(memory, :system, 0)
    atom_bytes = Keyword.get(memory, :atom, 0)
    binary_bytes = Keyword.get(memory, :binary, 0)
    ets_bytes = Keyword.get(memory, :ets, 0)
    
    %{
      total_mb: div(total_bytes, 1024 * 1024),
      breakdown: %{
        processes_mb: div(processes_bytes, 1024 * 1024),
        system_mb: div(system_bytes, 1024 * 1024),
        atom_mb: div(atom_bytes, 1024 * 1024),
        binary_mb: div(binary_bytes, 1024 * 1024),  
        ets_mb: div(ets_bytes, 1024 * 1024)
      }
    }
  end

  defp collect_cpu_metrics do
    # Use :observer_backend for CPU info if available
    try do
      case :observer_backend.sys_info() do
        sys_info when is_list(sys_info) ->
          # Look for CPU information in the system info
          cpu_info = Enum.find(sys_info, fn {key, _} -> key == :cpu end)
          case cpu_info do
            {:cpu, cpu_data} when is_list(cpu_data) ->
              # Try to extract CPU usage percentage
              usage_info = Enum.find(cpu_data, fn {key, _} -> key == :usage end)
              case usage_info do
                {:usage, usage} when is_number(usage) -> Float.round(usage, 2)
                _ -> estimate_cpu_usage()
              end
            _ -> estimate_cpu_usage()
          end
        _ -> estimate_cpu_usage()
      end
    catch
      _type, _error ->
        estimate_cpu_usage()
    end
  end

  defp estimate_cpu_usage do
    # Fallback: Estimate CPU usage based on scheduler utilization
    try do
      _schedulers = :erlang.system_info(:schedulers)
      # For now, just return a placeholder value
      # Real CPU monitoring would require a more sophisticated approach
      0.0
    catch
      _type, _error -> 0.0
    end
  end

  defp collect_process_metrics do
    :erlang.system_info(:process_count)
  end

  defp collect_corrosion_connection_metrics do
    # Check for active HTTP connections to Corrosion API
    # This is an approximation - for now return 0
    # TODO: Implement proper connection counting
    0
  end

  defp collect_message_queue_metrics do
    # Get message queue lengths for key processes
    key_processes = [
      CorroPort.MessagePropagation,
      CorroPort.AckTracker,
      CorroPort.AnalyticsStorage,
      __MODULE__
    ]
    
    total_queue_length = Enum.reduce(key_processes, 0, fn process_name, acc ->
      try do
        case Process.whereis(process_name) do
          nil -> acc
          pid ->
            case Process.info(pid, :message_queue_len) do
              {:message_queue_len, len} -> acc + len
              _ -> acc
            end
        end
      catch
        _type, _error -> acc
      end
    end)
    
    total_queue_length
  end
end
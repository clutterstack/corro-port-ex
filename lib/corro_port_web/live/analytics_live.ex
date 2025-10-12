defmodule CorroPortWeb.AnalyticsLive do
  @moduledoc """
  Real-time analytics dashboard for monitoring cluster experiments.

  This LiveView provides a comprehensive dashboard for tracking:
  - Experiment progress and status
  - Cluster-wide message timing statistics
  - System metrics from all nodes
  - Real-time aggregated data updates

  The dashboard automatically refreshes with data from the AnalyticsAggregator
  and subscribes to PubSub updates for real-time monitoring.
  """

  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{AnalyticsAggregator, LocalNode}
  alias CorroPortWeb.NavTabs
  alias CorroPortWeb.AnalyticsLive.{DataLoader, Helpers}

  # Import all component modules
  import CorroPortWeb.AnalyticsLive.ExperimentHistoryComponent
  import CorroPortWeb.AnalyticsLive.ExperimentControlsComponent
  import CorroPortWeb.AnalyticsLive.ExperimentSummaryComponent
  import CorroPortWeb.AnalyticsLive.NodePerformanceComponent
  import CorroPortWeb.AnalyticsLive.LatencyHistogramComponent
  import CorroPortWeb.AnalyticsLive.RttTimeSeriesComponent
  import CorroPortWeb.AnalyticsLive.ActiveNodesComponent
  import CorroPortWeb.AnalyticsLive.TimingStatsComponent
  import CorroPortWeb.AnalyticsLive.SystemMetricsComponent

  @impl true
  def mount(_params, _session, socket) do
    # Check if there's already a running experiment
    current_experiment_id = AnalyticsAggregator.get_current_experiment_id()

    socket =
      if connected?(socket) do
        # Subscribe to running experiment if there is one
        if current_experiment_id do
          Phoenix.PubSub.subscribe(CorroPort.PubSub, "analytics:#{current_experiment_id}")
        end

        # Start periodic refresh only if experiment is running
        if current_experiment_id do
          Helpers.schedule_refresh()
        end

        socket
        |> assign(:current_experiment, current_experiment_id)
        |> assign(:aggregation_status, if(current_experiment_id, do: :running, else: :stopped))
      else
        socket
        |> assign(:current_experiment, nil)
        |> assign(:aggregation_status, :stopped)
      end

    socket =
      socket
      |> assign(:page_title, "Analytics Dashboard")
      |> assign(:cluster_summary, nil)
      |> assign(:timing_stats, [])
      |> assign(:system_metrics, [])
      |> assign(:active_nodes, [])
      |> assign(:node_performance_stats, [])
      |> assign(:latency_histogram, nil)
      |> assign(:rtt_time_series, [])
      |> assign(:last_update, nil)
      |> assign(:refresh_interval, 5000)
      |> assign(:local_node_id, LocalNode.get_node_id())
      |> assign(:message_count, 10)
      |> assign(:message_interval_ms, 1000)
      |> assign(:message_progress, nil)
      |> assign(:experiment_history, [])
      |> assign(:viewing_mode, :current)
      |> assign(:transport_mode, :corrosion)
      |> assign(:experiment_id, "")
      |> assign(:show_confirm_delete, false)
      |> assign(:confirm_delete_experiment_id, nil)
      |> assign(:show_confirm_clear, false)

    # Load data if there's a running experiment
    socket =
      if current_experiment_id do
        DataLoader.load_experiment_data(socket)
      else
        socket
      end

    # Load experiment history
    socket = DataLoader.load_experiment_history(socket)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    experiment_id = Map.get(params, "experiment_id")

    socket =
      if experiment_id && experiment_id != socket.assigns.current_experiment do
        # Subscribe to this specific experiment's updates
        if connected?(socket) and experiment_id do
          Phoenix.PubSub.subscribe(CorroPort.PubSub, "analytics:#{experiment_id}")
        end

        socket
        |> assign(:current_experiment, experiment_id)
        |> DataLoader.load_experiment_data()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_aggregation", params, socket) do
    experiment_id = Map.get(params, "experiment_id")
    message_count = String.to_integer(Map.get(params, "message_count", "0"))
    message_interval_ms = String.to_integer(Map.get(params, "message_interval_ms", "1000"))
    transport_mode = String.to_existing_atom(Map.get(params, "transport_mode", "corrosion"))

    opts = [
      message_count: message_count,
      message_interval_ms: message_interval_ms,
      transport_mode: transport_mode
    ]

    case AnalyticsAggregator.start_experiment_aggregation(experiment_id, opts) do
      :ok ->
        # Subscribe to this specific experiment's updates
        if connected?(socket) do
          Phoenix.PubSub.subscribe(CorroPort.PubSub, "analytics:#{experiment_id}")
        end

        message_progress =
          if message_count > 0 do
            %{sent: 0, total: message_count}
          else
            nil
          end

        socket =
          socket
          |> assign(:current_experiment, experiment_id)
          |> assign(:aggregation_status, :running)
          |> assign(:viewing_mode, :current)
          |> assign(:message_progress, message_progress)
          |> put_flash(:info, "Started experiment #{experiment_id}" <> if(message_count > 0, do: " with #{message_count} messages", else: ""))
          |> push_patch(to: ~p"/analytics?experiment_id=#{experiment_id}")

        # Start refresh polling for the running experiment
        Helpers.schedule_refresh()

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start aggregation: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_aggregation", _params, socket) do
    case AnalyticsAggregator.stop_experiment_aggregation() do
      :ok ->
        socket =
          socket
          |> assign(:aggregation_status, :stopped)
          |> assign(:current_experiment, nil)
          |> assign(:message_progress, nil)
          |> put_flash(:info, "Stopped experiment aggregation")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to stop aggregation: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_message_count", %{"message_count" => value}, socket) do
    case Integer.parse(value) do
      {count, _} when count >= 0 ->
        {:noreply, assign(socket, :message_count, count)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_message_interval", %{"message_interval_ms" => value}, socket) do
    case Integer.parse(value) do
      {interval, _} when interval >= 100 ->
        {:noreply, assign(socket, :message_interval_ms, interval)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_transport_mode", %{"transport_mode" => mode}, socket) do
    transport_mode = String.to_existing_atom(mode)
    {:noreply, assign(socket, :transport_mode, transport_mode)}
  end

  @impl true
  def handle_event("update_transport_mode", _params, socket) do
    # Fallback for when called without params
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_form", %{"experiment_id" => experiment_id} = _params, socket) do
    {:noreply, assign(socket, :experiment_id, experiment_id)}
  end

  @impl true
  def handle_event("view_experiment", %{"experiment_id" => experiment_id}, socket) do
    socket =
      socket
      |> assign(:current_experiment, experiment_id)
      |> assign(:viewing_mode, :historical)
      |> assign(:aggregation_status, :stopped)
      |> DataLoader.load_experiment_data()
      |> push_patch(to: ~p"/analytics?experiment_id=#{experiment_id}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_view", _params, socket) do
    socket =
      socket
      |> assign(:current_experiment, nil)
      |> assign(:viewing_mode, :current)
      |> assign(:cluster_summary, nil)
      |> assign(:timing_stats, [])
      |> assign(:system_metrics, [])
      |> assign(:node_performance_stats, [])
      |> assign(:latency_histogram, nil)
      |> assign(:rtt_time_series, [])

    {:noreply, push_patch(socket, to: ~p"/analytics")}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    socket = DataLoader.load_experiment_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_refresh_interval", %{"interval" => interval_str}, socket) do
    case Integer.parse(interval_str) do
      {interval, _} when interval >= 1000 ->
        socket = assign(socket, :refresh_interval, interval)
        Helpers.schedule_refresh(interval)
        {:noreply, socket}

      _ ->
        socket = put_flash(socket, :error, "Invalid refresh interval")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_delete_experiment", %{"experiment_id" => experiment_id}, socket) do
    socket =
      socket
      |> assign(:show_confirm_delete, true)
      |> assign(:confirm_delete_experiment_id, experiment_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    socket =
      socket
      |> assign(:show_confirm_delete, false)
      |> assign(:confirm_delete_experiment_id, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_experiment", %{"experiment_id" => experiment_id}, socket) do
    alias CorroPort.Analytics

    case Analytics.delete_experiment(experiment_id) do
      {:ok, deleted_counts} ->
        total_deleted =
          deleted_counts.message_events +
            deleted_counts.topology_snapshots +
            deleted_counts.system_metrics

        socket =
          socket
          |> assign(:show_confirm_delete, false)
          |> assign(:confirm_delete_experiment_id, nil)
          |> put_flash(:info, "Deleted experiment #{experiment_id} (#{total_deleted} records)")
          |> DataLoader.load_experiment_history()

        # If the deleted experiment was currently being viewed, clear the view
        socket =
          if socket.assigns.current_experiment == experiment_id do
            socket
            |> assign(:current_experiment, nil)
            |> assign(:viewing_mode, :current)
            |> assign(:cluster_summary, nil)
            |> assign(:timing_stats, [])
            |> assign(:system_metrics, [])
            |> assign(:node_performance_stats, [])
            |> assign(:latency_histogram, nil)
            |> assign(:rtt_time_series, [])
            |> push_patch(to: ~p"/analytics")
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:show_confirm_delete, false)
          |> assign(:confirm_delete_experiment_id, nil)
          |> put_flash(:error, "Failed to delete experiment: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_clear_all", _params, socket) do
    socket = assign(socket, :show_confirm_clear, true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_clear_all", _params, socket) do
    socket = assign(socket, :show_confirm_clear, false)
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_all_experiments", _params, socket) do
    alias CorroPort.Analytics

    case Analytics.delete_all_experiments() do
      {:ok, deleted_counts} ->
        total_deleted =
          deleted_counts.message_events +
            deleted_counts.topology_snapshots +
            deleted_counts.system_metrics

        socket =
          socket
          |> assign(:show_confirm_clear, false)
          |> assign(:current_experiment, nil)
          |> assign(:viewing_mode, :current)
          |> assign(:cluster_summary, nil)
          |> assign(:timing_stats, [])
          |> assign(:system_metrics, [])
          |> assign(:node_performance_stats, [])
          |> assign(:latency_histogram, nil)
          |> assign(:rtt_time_series, [])
          |> put_flash(:info, "Cleared all experiment history (#{total_deleted} records)")
          |> DataLoader.load_experiment_history()
          |> push_patch(to: ~p"/analytics")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:show_confirm_clear, false)
          |> put_flash(:error, "Failed to clear history: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    # Only refresh if viewing current experiment that's still running
    should_refresh =
      socket.assigns.viewing_mode == :current and
        socket.assigns.aggregation_status == :running

    socket =
      if should_refresh do
        DataLoader.load_experiment_data(socket)
      else
        socket
      end

    # Only schedule next refresh if we should keep polling
    if should_refresh do
      Helpers.schedule_refresh()
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:cluster_update, %{experiment_id: experiment_id}}, socket) do
    if experiment_id == socket.assigns.current_experiment do
      socket = DataLoader.load_experiment_data(socket)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:message_progress, %{sent_count: sent, total_count: total}}, socket) do
    socket = assign(socket, :message_progress, %{sent: sent, total: total})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:experiment_stopped, experiment_id}, socket) do
    if experiment_id == socket.assigns.current_experiment do
      # Load final experiment data
      socket = DataLoader.load_experiment_data(socket)

      socket =
        socket
        |> assign(:aggregation_status, :stopped)
        |> assign(:message_progress, %{sent: 0, total: 0})
        |> put_flash(:info, "Experiment completed - all messages sent")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Template

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto">
      <!-- Navigation -->
      <div class="mb-6">
        <NavTabs.nav_tabs active={:analytics} />
      </div>

      <!-- Header -->
      <div class="mb-8">
        <h1 class="text-3xl font-bold text-base-content mb-2">Analytics Dashboard</h1>
        <p class="text-base-content/70">Real-time cluster experiment monitoring</p>
      </div>

      <!-- Experiment History -->
      <.experiment_history
        experiment_history={@experiment_history}
        current_experiment={@current_experiment}
        viewing_mode={@viewing_mode}
        show_confirm_delete={@show_confirm_delete}
        confirm_delete_experiment_id={@confirm_delete_experiment_id}
        show_confirm_clear={@show_confirm_clear}
      />

      <!-- Experiment Controls -->
      <.experiment_controls
        current_experiment={@current_experiment}
        aggregation_status={@aggregation_status}
        message_count={@message_count}
        message_interval_ms={@message_interval_ms}
        message_progress={@message_progress}
        refresh_interval={@refresh_interval}
        last_update={@last_update}
        transport_mode={@transport_mode}
        experiment_id={@experiment_id}
      />

      <%= if @current_experiment do %>
        <!-- Experiment Summary -->
        <.experiment_summary
          experiment_id={@current_experiment}
          cluster_summary={@cluster_summary}
          active_nodes={@active_nodes}
          local_node_id={@local_node_id}
        />

        <!-- Node Performance Statistics -->
        <.node_performance_table node_performance_stats={@node_performance_stats} />

        <!-- Latency Histogram -->
        <.latency_histogram_chart latency_histogram={@latency_histogram} />

        <!-- RTT Time Series -->
        <.rtt_time_series_chart rtt_time_series={@rtt_time_series} />

        <!-- Active Nodes -->
        <.active_nodes_grid active_nodes={@active_nodes} />

        <!-- Timing Statistics -->
        <.timing_stats_table timing_stats={@timing_stats} />

        <!-- System Metrics -->
        <.system_metrics system_metrics={@system_metrics} />
      <% else %>
        <div class="card bg-base-200 text-center">
          <div class="card-body">
            <h3 class="card-title text-lg mb-2">No Experiment Selected</h3>
            <p class="text-base-content/70">Enter an experiment ID above to start monitoring</p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end

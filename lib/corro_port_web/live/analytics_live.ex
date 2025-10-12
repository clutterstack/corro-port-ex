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

  alias CorroPort.{AnalyticsAggregator, Analytics, LocalNode}
  alias CorroPort.Analytics.Queries
  alias CorroPortWeb.NavTabs

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
          schedule_refresh()
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
      |> assign(:viewing_mode, :current) # :current or :historical

    # Load data if there's a running experiment
    socket =
      if current_experiment_id do
        load_experiment_data(socket)
      else
        socket
      end

    # Load experiment history
    socket = load_experiment_history(socket)

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
        |> load_experiment_data()
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

    opts = [
      message_count: message_count,
      message_interval_ms: message_interval_ms
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
        schedule_refresh()

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
  def handle_event("view_experiment", %{"experiment_id" => experiment_id}, socket) do
    socket =
      socket
      |> assign(:current_experiment, experiment_id)
      |> assign(:viewing_mode, :historical)
      |> assign(:aggregation_status, :stopped)
      |> load_experiment_data()
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
    socket = load_experiment_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_refresh_interval", %{"interval" => interval_str}, socket) do
    case Integer.parse(interval_str) do
      {interval, _} when interval >= 1000 ->
        socket = assign(socket, :refresh_interval, interval)
        schedule_refresh(interval)
        {:noreply, socket}

      _ ->
        socket = put_flash(socket, :error, "Invalid refresh interval")
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
        load_experiment_data(socket)
      else
        socket
      end

    # Only schedule next refresh if we should keep polling
    if should_refresh do
      schedule_refresh()
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:cluster_update, %{experiment_id: experiment_id}}, socket) do
    if experiment_id == socket.assigns.current_experiment do
      socket = load_experiment_data(socket)
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
      socket = load_experiment_data(socket)

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
      <%= if @experiment_history != [] do %>
        <div class="card bg-base-200 mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h3 class="card-title text-lg">Experiment History</h3>
              <%= if @current_experiment && @viewing_mode == :historical do %>
                <button
                  phx-click="clear_view"
                  class="text-sm text-primary hover:text-primary-focus"
                >
                  Clear Selection
                </button>
              <% end %>
            </div>

            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr class="bg-base-300">
                    <th class="text-base-content">Experiment ID</th>
                    <th class="text-base-content">Started</th>
                    <th class="text-base-content">Duration</th>
                    <th class="text-base-content">Messages</th>
                    <th class="text-base-content">Acks</th>
                    <th class="text-base-content">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for exp <- Enum.take(@experiment_history, 10) do %>
                    <tr class={[
                      "hover:bg-base-300/50",
                      if(@current_experiment == exp.id, do: "bg-primary/10", else: "")
                    ]}>
                      <td class="font-mono">{exp.id}</td>
                      <td>
                        <%= if exp.time_range do %>
                          {format_datetime(exp.time_range.start)}
                        <% else %>
                          <span class="text-base-content/40">-</span>
                        <% end %>
                      </td>
                      <td>
                        <%= if exp.duration_seconds do %>
                          {exp.duration_seconds}s
                        <% else %>
                          <span class="text-base-content/40">-</span>
                        <% end %>
                      </td>
                      <td>{exp.send_count}</td>
                      <td>{exp.ack_count}</td>
                      <td>
                        <button
                          phx-click="view_experiment"
                          phx-value-experiment_id={exp.id}
                          class="text-primary hover:text-primary-focus text-sm"
                        >
                          View Details
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>

            <%= if length(@experiment_history) > 10 do %>
              <div class="mt-4 text-sm text-base-content/60 text-center">
                Showing 10 most recent experiments of {length(@experiment_history)} total
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

    <!-- Experiment Controls -->
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-4">Experiment Control</h3>

          <form phx-submit="start_aggregation" class="space-y-4">
            <!-- Experiment ID -->
            <div>
              <label class="block text-sm font-medium text-base-content mb-2">
                Experiment ID
              </label>
              <input
                type="text"
                name="experiment_id"
                placeholder="Enter experiment ID"
                value={@current_experiment}
                class="input input-bordered w-full"
                required
                disabled={@aggregation_status == :running}
              />
            </div>

            <!-- Message Sending Configuration -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-base-content mb-2">
                  Number of Messages (0 = manual sending)
                </label>
                <input
                  type="number"
                  name="message_count"
                  value={@message_count}
                  min="0"
                  max="1000"
                  class="input input-bordered w-full"
                  disabled={@aggregation_status == :running}
                  phx-change="update_message_count"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-base-content mb-2">
                  Message Interval (ms)
                </label>
                <input
                  type="number"
                  name="message_interval_ms"
                  value={@message_interval_ms}
                  min="100"
                  max="60000"
                  step="100"
                  class="input input-bordered w-full"
                  disabled={@aggregation_status == :running}
                  phx-change="update_message_interval"
                />
              </div>
            </div>

            <!-- Action Buttons -->
            <div class="flex items-center gap-4">
              <button
                type="submit"
                class="btn btn-primary disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={@aggregation_status == :running}
              >
                Start Experiment
              </button>

              <button
                type="button"
                phx-click="stop_aggregation"
                class="btn btn-error disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={@aggregation_status == :stopped}
              >
                Stop
              </button>

              <button
                type="button"
                phx-click="refresh_now"
                class="btn btn-neutral"
              >
                Refresh Now
              </button>
            </div>
          </form>

          <!-- Status Bar -->
          <div class="mt-4 flex flex-wrap items-center gap-4 pt-4 border-t border-base-300">
            <div class="flex items-center gap-2">
              <span class="text-sm text-base-content/70">Status:</span>
              <span class={[
                "badge",
                if(@aggregation_status == :running,
                  do: "badge-success",
                  else: "badge-ghost"
                )
              ]}>
                {String.capitalize(to_string(@aggregation_status))}
              </span>
            </div>

            <%= if @message_progress do %>
              <div class="flex items-center gap-2">
                <span class="text-sm text-base-content/70">Messages:</span>
                <span class="badge badge-info">
                  {@message_progress.sent}/{@message_progress.total}
                </span>
                <%= if @message_progress.sent < @message_progress.total do %>
                  <div class="w-32 bg-base-300 rounded-full h-2">
                    <div
                      class="bg-primary h-2 rounded-full transition-all duration-300"
                      style={"width: #{Float.round(@message_progress.sent / @message_progress.total * 100, 1)}%"}
                    >
                    </div>
                  </div>
                <% else %>
                  <span class="text-xs text-success font-medium">Complete</span>
                <% end %>
              </div>
            <% end %>

            <div class="flex items-center gap-2">
              <span class="text-sm text-base-content/70">Refresh:</span>
              <select
                phx-change="set_refresh_interval"
                name="interval"
                class="select select-bordered select-sm"
              >
                <option value="1000" selected={@refresh_interval == 1000}>1s</option>
                <option value="5000" selected={@refresh_interval == 5000}>5s</option>
                <option value="10000" selected={@refresh_interval == 10000}>10s</option>
                <option value="30000" selected={@refresh_interval == 30000}>30s</option>
              </select>
            </div>

            <%= if @last_update do %>
              <div class="text-sm text-base-content/60">
                Last update: {format_time(@last_update)}
              </div>
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Experiment Summary -->
      <%= if @current_experiment do %>
        <div class="card bg-base-200 mb-6">
          <div class="card-body">
            <h3 class="card-title text-lg mb-4">
              Experiment: {@current_experiment}
            </h3>

            <%= if @cluster_summary do %>
              <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4">
                <div class="text-center">
                  <div class="text-2xl font-bold text-info">{@cluster_summary.node_count || 0}</div>
                  <div class="text-sm text-base-content/60">Nodes</div>
                </div>
                <div class="text-center">
                  <div class="text-2xl font-bold text-success">
                    {@cluster_summary.send_count || 0}
                  </div>
                  <div class="text-sm text-base-content/60">Messages Sent</div>
                </div>
                <div class="text-center">
                  <div class="text-2xl font-bold text-secondary">
                    {@cluster_summary.ack_count || 0}
                  </div>
                  <div class="text-sm text-base-content/60">Acknowledged</div>
                </div>
                <div class="text-center">
                  <div class="text-2xl font-bold text-warning">
                    {format_percentage(ack_rate(@cluster_summary,
                      active_nodes: @active_nodes,
                      local_node_id: @local_node_id
                    ))}
                  </div>
                  <div class="text-sm text-base-content/60">Ack Rate</div>
                </div>
                <div class="text-center">
                  <div class="text-2xl font-bold text-accent">
                    {@cluster_summary.system_metrics_count || 0}
                  </div>
                  <div class="text-sm text-base-content/60">Metrics</div>
                </div>
                <div class="text-center">
                  <div class="text-2xl font-bold text-base-content/70">
                    {@cluster_summary.topology_snapshots_count || 0}
                  </div>
                  <div class="text-sm text-base-content/60">Snapshots</div>
                </div>
              </div>
            <% else %>
              <div class="text-base-content/50 text-center py-8">
                No data available. Start aggregation to begin monitoring.
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Node Performance Statistics -->
        <%= if @node_performance_stats != [] do %>
          <div class="card bg-base-200 mb-6">
            <div class="card-body">
              <h3 class="card-title text-lg mb-4">Node Performance (RTT)</h3>
              <p class="text-sm text-base-content/70 mb-4">
                Round-trip time from Corrosion write (via gossip) to acknowledgement receipt
              </p>

              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr class="bg-base-300">
                      <th class="text-base-content">Node ID</th>
                      <th class="text-base-content">Total Acks</th>
                      <th class="text-base-content">Min RTT</th>
                      <th class="text-base-content">Avg RTT</th>
                      <th class="text-base-content">Max RTT</th>
                      <th class="text-base-content">P50</th>
                      <th class="text-base-content">P95</th>
                      <th class="text-base-content">P99</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for {node_stat, index} <- Enum.with_index(@node_performance_stats) do %>
                      <tr class={if(rem(index, 2) == 0, do: "", else: "bg-base-300/30")}>
                        <td class="font-mono font-medium">{node_stat.node_id}</td>
                        <td>{node_stat.ack_count}</td>
                        <td>
                          <span class={latency_color_class(node_stat.min_latency_ms)}>
                            {node_stat.min_latency_ms}ms
                          </span>
                        </td>
                        <td class="font-medium">
                          <span class={latency_color_class(node_stat.avg_latency_ms)}>
                            {node_stat.avg_latency_ms}ms
                          </span>
                        </td>
                        <td>
                          <span class={latency_color_class(node_stat.max_latency_ms)}>
                            {node_stat.max_latency_ms}ms
                          </span>
                        </td>
                        <td>{node_stat.p50_latency_ms}ms</td>
                        <td>{node_stat.p95_latency_ms}ms</td>
                        <td>{node_stat.p99_latency_ms}ms</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <div class="mt-4 flex items-center gap-4 text-xs text-base-content/70">
                <div class="flex items-center gap-2">
                  <span class="inline-block w-3 h-3 rounded-full bg-success"></span>
                  <span>&lt; 50ms (Excellent)</span>
                </div>
                <div class="flex items-center gap-2">
                  <span class="inline-block w-3 h-3 rounded-full bg-warning"></span>
                  <span>50-200ms (Good)</span>
                </div>
                <div class="flex items-center gap-2">
                  <span class="inline-block w-3 h-3 rounded-full bg-[#F97316]"></span>
                  <span>200-500ms (Fair)</span>
                </div>
                <div class="flex items-center gap-2">
                  <span class="inline-block w-3 h-3 rounded-full bg-error"></span>
                  <span>&gt; 500ms (Slow)</span>
                </div>
              </div>
            </div>
          </div>
        <% end %>

    <!-- Latency Distribution Histogram -->
        <%= if @latency_histogram && @latency_histogram.total_count > 0 do %>
          <div class="card bg-base-200 mb-6">
            <div class="card-body">
              <h3 class="card-title text-lg mb-2">Latency Distribution</h3>
              <p class="text-sm text-base-content/70 mb-4">
                Distribution of round-trip times across all {@ latency_histogram.total_count} acknowledgements
              </p>

              <!-- SVG Histogram -->
              <div class="w-full" style="height: 300px;">
                <%= render_latency_histogram(@latency_histogram) %>
              </div>

              <!-- Percentile Markers Legend -->
              <div class="mt-4 flex items-center gap-6 text-sm">
                <div class="flex items-center gap-2">
                  <div class="w-0.5 h-4 bg-info"></div>
                  <span class="text-base-content/70">
                    P50 (median): <span class="font-medium">{@latency_histogram.percentiles.p50}ms</span>
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <div class="w-0.5 h-4 bg-warning"></div>
                  <span class="text-base-content/70">
                    P95: <span class="font-medium">{@latency_histogram.percentiles.p95}ms</span>
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <div class="w-0.5 h-4 bg-error"></div>
                  <span class="text-base-content/70">
                    P99: <span class="font-medium">{@latency_histogram.percentiles.p99}ms</span>
                  </span>
                </div>
              </div>
            </div>
          </div>
        <% end %>

    <!-- RTT Time Series Plot -->
        <%= if @rtt_time_series != [] do %>
          <div class="card bg-base-200 mb-6">
            <div class="card-body">
              <h3 class="card-title text-lg mb-2">RTT Over Time by Node</h3>
              <p class="text-sm text-base-content/70 mb-4">
                Response time trends showing if nodes slow down as the experiment progresses
              </p>

              <!-- SVG Time Series Plot -->
              <div class="w-full" style="height: 400px;">
                <%= render_rtt_time_series(@rtt_time_series) %>
              </div>

              <div class="mt-4 text-sm text-base-content/70">
                Each line represents a different responding node. Look for upward trends that might indicate
                degradation due to load or gossip overhead.
              </div>
            </div>
          </div>
        <% end %>

    <!-- Active Nodes -->
        <div class="card bg-base-200 mb-6">
          <div class="card-body">
            <h3 class="card-title text-lg mb-4">Active Nodes</h3>

            <%= if @active_nodes != [] do %>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <%= for node <- @active_nodes do %>
                  <div class="border border-base-300 rounded-lg p-3 bg-base-100">
                    <div class="font-medium">{node.node_id}</div>
                    <div class="text-sm text-base-content/70">
                      Region: {node.region || "Unknown"}
                    </div>
                    <%= if node.phoenix_port do %>
                      <div class="text-sm text-base-content/70">
                        Port: {node.phoenix_port}
                      </div>
                    <% end %>
                    <%= if node.is_local do %>
                      <div class="badge badge-info badge-sm mt-1">
                        Local Node
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-base-content/50 text-center py-4">
                No active nodes detected
              </div>
            <% end %>
          </div>
        </div>

    <!-- Timing Statistics -->
        <div class="card bg-base-200 mb-6">
          <div class="card-body">
            <h3 class="card-title text-lg mb-4">Message Timing Statistics</h3>

            <%= if @timing_stats != [] do %>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr class="bg-base-300">
                      <th class="text-base-content">Message ID</th>
                      <th class="text-base-content">Send Time</th>
                      <th class="text-base-content">Acks</th>
                      <th class="text-base-content">Min Latency</th>
                      <th class="text-base-content">Max Latency</th>
                      <th class="text-base-content">Avg Latency</th>
                      <th class="text-base-content">Nodes</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for stat <- @timing_stats do %>
                      <tr class="hover:bg-base-300/50">
                        <td class="font-mono">{stat.message_id}</td>
                        <td>{format_datetime(stat.send_time)}</td>
                        <td>{stat.ack_count}</td>
                        <td>
                          <%= if stat.min_latency_ms do %>
                            {stat.min_latency_ms}ms
                          <% else %>
                            <span class="text-base-content/40">-</span>
                          <% end %>
                        </td>
                        <td>
                          <%= if stat.max_latency_ms do %>
                            {stat.max_latency_ms}ms
                          <% else %>
                            <span class="text-base-content/40">-</span>
                          <% end %>
                        </td>
                        <td>
                          <%= if stat.avg_latency_ms do %>
                            {stat.avg_latency_ms}ms
                          <% else %>
                            <span class="text-base-content/40">-</span>
                          <% end %>
                        </td>
                        <td>{length(stat.acknowledgments)}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% else %>
              <div class="text-base-content/50 text-center py-8">
                No timing statistics available
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- System Metrics Chart -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-lg mb-4">System Metrics</h3>

            <%= if @system_metrics != [] do %>
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
                <!-- Memory Usage -->
                <div>
                  <h4 class="font-medium mb-2">Memory Usage (MB)</h4>
                  <div class="space-y-2">
                    <%= for metric <- Enum.take(@system_metrics, 10) do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class="text-base-content/70">{metric.node_id}</span>
                        <span class="font-medium">{metric.memory_mb} MB</span>
                      </div>
                    <% end %>
                  </div>
                </div>

      <!-- Process Count -->
                <div>
                  <h4 class="font-medium mb-2">Erlang Processes</h4>
                  <div class="space-y-2">
                    <%= for metric <- Enum.take(@system_metrics, 10) do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class="text-base-content/70">{metric.node_id}</span>
                        <span class="font-medium">{metric.erlang_processes}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="text-base-content/50 text-center py-8">
                No system metrics available
              </div>
            <% end %>
          </div>
        </div>
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

  # Private functions

  defp load_experiment_data(socket) do
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
      |> assign(:cluster_summary, cluster_summary)
      |> assign(:timing_stats, timing_stats)
      |> assign(:system_metrics, system_metrics)
      |> assign(:active_nodes, active_nodes)
      |> assign(:node_performance_stats, node_performance_stats)
      |> assign(:latency_histogram, latency_histogram)
      |> assign(:rtt_time_series, rtt_time_series)
      |> assign(:last_update, DateTime.utc_now())
    else
      socket
    end
  end

  defp load_experiment_history(socket) do
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
          duration_seconds: calculate_duration(summary.time_range)
        }
      end)
      |> Enum.sort_by(fn exp ->
        case exp.time_range do
          %{start: start} -> start
          _ -> ~U[1970-01-01 00:00:00Z]
        end
      end, {:desc, DateTime})

    assign(socket, :experiment_history, history)
  end

  defp ack_rate(summary, opts \\ [])
  defp ack_rate(nil, _opts), do: 0.0

  defp ack_rate(summary, opts) do
    send_count = Map.get(summary, :send_count, 0)
    ack_count = Map.get(summary, :ack_count, 0)
    expected_acks = send_count * ack_node_count(summary, opts)

    if expected_acks > 0 do
      Float.round(ack_count / expected_acks * 100, 1)
    else
      0.0
    end
  end

  defp ack_node_count(summary, opts) do
    cond do
      is_integer(Map.get(summary, :remote_node_count)) and Map.get(summary, :remote_node_count) >= 0 ->
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

  defp remote_count_from_active_nodes(opts) do
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

  defp format_percentage(nil), do: "0%"

  defp format_percentage(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
    |> Kernel.<>("%")
  end

  defp format_percentage(value) when is_integer(value) do
    "#{value}%"
  end

  defp calculate_duration(nil), do: nil
  defp calculate_duration(%{start: start_time, end: end_time}) do
    DateTime.diff(end_time, start_time, :second)
  end

  defp schedule_refresh(interval \\ nil) do
    interval = interval || 5000
    Process.send_after(self(), :refresh, interval)
  end

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(other), do: to_string(other)

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_time()
    |> Time.to_string()
  end

  defp format_time(_), do: "-"

  defp latency_color_class(latency_ms) when is_number(latency_ms) do
    cond do
      latency_ms < 50 -> "text-green-600 font-medium"
      latency_ms < 200 -> "text-yellow-600 font-medium"
      latency_ms < 500 -> "text-orange-600 font-medium"
      true -> "text-red-600 font-medium"
    end
  end

  defp latency_color_class(_), do: "text-gray-600"

  defp render_latency_histogram(histogram) do
    chart_height = 250
    chart_width = 800
    padding = %{top: 20, right: 20, bottom: 40, left: 60}

    plot_width = chart_width - padding.left - padding.right
    plot_height = chart_height - padding.top - padding.bottom

    buckets = histogram.buckets
    max_count = histogram.max_count
    bucket_count = length(buckets)

    bar_width = if bucket_count > 0, do: plot_width / bucket_count * 0.8, else: 0
    bar_spacing = if bucket_count > 0, do: plot_width / bucket_count, else: 0

    assigns = %{
      chart_width: chart_width,
      chart_height: chart_height,
      padding: padding,
      plot_width: plot_width,
      plot_height: plot_height,
      buckets: buckets,
      max_count: max_count,
      bar_width: bar_width,
      bar_spacing: bar_spacing,
      percentiles: histogram.percentiles
    }

    ~H"""
    <svg width="100%" height="100%" viewBox={"0 0 #{@chart_width} #{@chart_height}"} class="border border-gray-200 rounded">
      <!-- Y-axis -->
      <line
        x1={@padding.left}
        y1={@padding.top}
        x2={@padding.left}
        y2={@chart_height - @padding.bottom}
        stroke="#9CA3AF"
        stroke-width="1"
      />
      <!-- X-axis -->
      <line
        x1={@padding.left}
        y1={@chart_height - @padding.bottom}
        x2={@chart_width - @padding.right}
        y2={@chart_height - @padding.bottom}
        stroke="#9CA3AF"
        stroke-width="1"
      />

      <!-- Y-axis label -->
      <text x="20" y={@padding.top + @plot_height / 2} text-anchor="middle" transform={"rotate(-90, 20, #{@padding.top + @plot_height / 2})"} class="text-xs fill-gray-600">
        Count
      </text>

      <!-- X-axis label -->
      <text x={@padding.left + @plot_width / 2} y={@chart_height - 5} text-anchor="middle" class="text-xs fill-gray-600">
        Latency (ms)
      </text>

      <!-- Y-axis ticks -->
      <%= for i <- 0..5 do %>
        <% y = @chart_height - @padding.bottom - (@plot_height * i / 5) %>
        <% value = Float.round(@max_count * i / 5, 1) %>
        <line x1={@padding.left - 5} y1={y} x2={@padding.left} y2={y} stroke="#9CA3AF" stroke-width="1" />
        <text x={@padding.left - 10} y={y + 4} text-anchor="end" class="text-xs fill-gray-600">
          {value}
        </text>
      <% end %>

      <!-- Bars -->
      <%= for {bucket, index} <- Enum.with_index(@buckets) do %>
        <% x = @padding.left + index * @bar_spacing %>
        <% bar_height = if @max_count > 0, do: bucket.count / @max_count * @plot_height, else: 0 %>
        <% y = @chart_height - @padding.bottom - bar_height %>
        <% fill_color = bucket_fill_color(bucket.min) %>

        <!-- Bar -->
        <rect
          x={x}
          y={y}
          width={@bar_width}
          height={bar_height}
          fill={fill_color}
          opacity="0.8"
        />

        <!-- Count label on top of bar -->
        <%= if bucket.count > 0 do %>
          <text x={x + @bar_width / 2} y={y - 5} text-anchor="middle" class="text-xs fill-gray-700 font-medium">
            {bucket.count}
          </text>
        <% end %>

        <!-- X-axis label -->
        <text
          x={x + @bar_width / 2}
          y={@chart_height - @padding.bottom + 15}
          text-anchor="middle"
          class="text-xs fill-gray-600"
          transform={"rotate(-45, #{x + @bar_width / 2}, #{@chart_height - @padding.bottom + 15})"}
        >
          {bucket.label}
        </text>
      <% end %>

      <!-- Percentile markers -->
      <%= for {percentile_name, percentile_value, color} <- [{"P50", @percentiles.p50, "#3B82F6"}, {"P95", @percentiles.p95, "#F97316"}, {"P99", @percentiles.p99, "#EF4444"}] do %>
        <%= if percentile_value do %>
          <% x_pos = calculate_percentile_position(percentile_value, @buckets, @bar_spacing, @padding.left) %>
          <line
            x1={x_pos}
            y1={@padding.top}
            x2={x_pos}
            y2={@chart_height - @padding.bottom}
            stroke={color}
            stroke-width="2"
            stroke-dasharray="5,5"
            opacity="0.7"
          />
          <text x={x_pos + 5} y={@padding.top + 15} class="text-xs font-medium" fill={color}>
            {percentile_name}
          </text>
        <% end %>
      <% end %>
    </svg>
    """
  end

  defp bucket_fill_color(min_latency) do
    cond do
      min_latency < 50 -> "#10B981"
      min_latency < 200 -> "#F59E0B"
      min_latency < 500 -> "#F97316"
      true -> "#EF4444"
    end
  end

  defp calculate_percentile_position(percentile_value, buckets, bar_spacing, left_padding) do
    # Find which bucket the percentile falls into
    bucket_index =
      buckets
      |> Enum.find_index(fn bucket ->
        case bucket.max do
          :infinity -> percentile_value >= bucket.min
          max_val -> percentile_value >= bucket.min && percentile_value < max_val
        end
      end)

    case bucket_index do
      nil -> left_padding
      index -> left_padding + index * bar_spacing + bar_spacing / 2
    end
  end

  defp render_rtt_time_series(rtt_time_series) do
    # Extract all data points to determine ranges
    all_points =
      rtt_time_series
      |> Enum.flat_map(fn series -> series.data_points end)

    if all_points == [] do
      assigns = %{}

      ~H"""
      <div class="text-base-content/50 text-center py-8">
        No RTT data available
      </div>
      """
    else
      chart_height = 400
      chart_width = 900
      padding = %{top: 20, right: 120, bottom: 60, left: 60}

      plot_width = chart_width - padding.left - padding.right
      plot_height = chart_height - padding.top - padding.bottom
      # Calculate time range
      all_times = Enum.map(all_points, & &1.send_time)
      min_time = Enum.min(all_times, DateTime)
      max_time = Enum.max(all_times, DateTime)
      time_range_seconds = DateTime.diff(max_time, min_time, :second)

      # Calculate RTT range
      all_rtts = Enum.map(all_points, & &1.rtt_ms)
      min_rtt = Enum.min(all_rtts)
      max_rtt = Enum.max(all_rtts)
      rtt_range = max_rtt - min_rtt

      # Add 10% padding to RTT range for better visualization
      rtt_padding = max(rtt_range * 0.1, 10)
      plot_min_rtt = max(0, min_rtt - rtt_padding)
      plot_max_rtt = max_rtt + rtt_padding

      # Node colors - cycle through a palette
      node_colors = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6", "#F97316"]

      assigns = %{
        chart_width: chart_width,
        chart_height: chart_height,
        padding: padding,
        plot_width: plot_width,
        plot_height: plot_height,
        rtt_time_series: rtt_time_series,
        min_time: min_time,
        max_time: max_time,
        time_range_seconds: time_range_seconds,
        plot_min_rtt: plot_min_rtt,
        plot_max_rtt: plot_max_rtt,
        rtt_range: plot_max_rtt - plot_min_rtt,
        node_colors: node_colors
      }

      ~H"""
      <svg width="100%" height="100%" viewBox={"0 0 #{@chart_width} #{@chart_height}"} class="border border-gray-200 rounded">
        <!-- Y-axis -->
        <line
          x1={@padding.left}
          y1={@padding.top}
          x2={@padding.left}
          y2={@chart_height - @padding.bottom}
          stroke="#9CA3AF"
          stroke-width="1"
        />
        <!-- X-axis -->
        <line
          x1={@padding.left}
          y1={@chart_height - @padding.bottom}
          x2={@chart_width - @padding.right}
          y2={@chart_height - @padding.bottom}
          stroke="#9CA3AF"
          stroke-width="1"
        />

        <!-- Y-axis label -->
        <text x="20" y={@padding.top + @plot_height / 2} text-anchor="middle" transform={"rotate(-90, 20, #{@padding.top + @plot_height / 2})"} class="text-sm fill-gray-600">
          RTT (ms)
        </text>

        <!-- X-axis label -->
        <text x={@padding.left + @plot_width / 2} y={@chart_height - 5} text-anchor="middle" class="text-sm fill-gray-600">
          Message Send Time
        </text>

        <!-- Y-axis ticks -->
        <%= for i <- 0..5 do %>
          <% y = @chart_height - @padding.bottom - (@plot_height * i / 5) %>
          <% value = Float.round(@plot_min_rtt + (@rtt_range * i / 5), 1) %>
          <line x1={@padding.left - 5} y1={y} x2={@padding.left} y2={y} stroke="#9CA3AF" stroke-width="1" />
          <text x={@padding.left - 10} y={y + 4} text-anchor="end" class="text-xs fill-gray-600">
            {value}
          </text>
        <% end %>

        <!-- X-axis ticks (time) -->
        <%= for i <- 0..4 do %>
          <% x = @padding.left + (@plot_width * i / 4) %>
          <% time_offset = @time_range_seconds * i / 4 %>
          <% tick_time = DateTime.add(@min_time, trunc(time_offset), :second) %>
          <line x1={x} y1={@chart_height - @padding.bottom} y2={@chart_height - @padding.bottom + 5} stroke="#9CA3AF" stroke-width="1" />
          <text x={x} y={@chart_height - @padding.bottom + 20} text-anchor="middle" class="text-xs fill-gray-600">
            {format_time_tick(tick_time)}
          </text>
        <% end %>

        <!-- Plot data for each node -->
        <%= for {series, series_index} <- Enum.with_index(@rtt_time_series) do %>
          <% color = Enum.at(@node_colors, rem(series_index, length(@node_colors))) %>

          <!-- Points and connecting lines -->
          <%= if length(series.data_points) > 1 do %>
            <% path_data = build_line_path(series.data_points, @min_time, @time_range_seconds, @plot_min_rtt, @rtt_range, @padding, @plot_width, @plot_height) %>
            <path d={path_data} fill="none" stroke={color} stroke-width="2" opacity="0.7" />
          <% end %>

          <!-- Data points -->
          <%= for point <- series.data_points do %>
            <% x = calculate_x_position(point.send_time, @min_time, @time_range_seconds, @padding.left, @plot_width) %>
            <% y = calculate_y_position(point.rtt_ms, @plot_min_rtt, @rtt_range, @chart_height, @padding.bottom, @plot_height) %>
            <circle cx={x} cy={y} r="3" fill={color} opacity="0.8" />
          <% end %>
        <% end %>

        <!-- Legend -->
        <%= for {series, series_index} <- Enum.with_index(@rtt_time_series) do %>
          <% color = Enum.at(@node_colors, rem(series_index, length(@node_colors))) %>
          <% legend_y = @padding.top + 20 + (series_index * 20) %>
          <circle cx={@chart_width - @padding.right + 15} cy={legend_y} r="4" fill={color} />
          <text x={@chart_width - @padding.right + 25} y={legend_y + 4} class="text-xs fill-gray-700">
            {series.node_id}
          </text>
        <% end %>
      </svg>
      """
    end
  end

  defp format_time_tick(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0..7)
  end

  defp calculate_x_position(time, min_time, time_range_seconds, left_padding, plot_width) do
    if time_range_seconds > 0 do
      time_offset = DateTime.diff(time, min_time, :second)
      left_padding + (time_offset / time_range_seconds * plot_width)
    else
      left_padding + plot_width / 2
    end
  end

  defp calculate_y_position(rtt_ms, plot_min_rtt, rtt_range, chart_height, bottom_padding, plot_height) do
    if rtt_range > 0 do
      normalized = (rtt_ms - plot_min_rtt) / rtt_range
      chart_height - bottom_padding - (normalized * plot_height)
    else
      chart_height - bottom_padding - (plot_height / 2)
    end
  end

  defp build_line_path(data_points, min_time, time_range_seconds, plot_min_rtt, rtt_range, padding, plot_width, plot_height) do
    chart_height = padding.top + plot_height + padding.bottom

    data_points
    |> Enum.map(fn point ->
      x = calculate_x_position(point.send_time, min_time, time_range_seconds, padding.left, plot_width)
      y = calculate_y_position(point.rtt_ms, plot_min_rtt, rtt_range, chart_height, padding.bottom, plot_height)
      {x, y}
    end)
    |> Enum.with_index()
    |> Enum.map(fn {{x, y}, index} ->
      if index == 0 do
        "M #{x} #{y}"
      else
        "L #{x} #{y}"
      end
    end)
    |> Enum.join(" ")
  end
end

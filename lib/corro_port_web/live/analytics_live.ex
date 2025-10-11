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

        # Start periodic refresh
        schedule_refresh()

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
          |> assign(:message_progress, message_progress)
          |> put_flash(:info, "Started experiment #{experiment_id}" <> if(message_count > 0, do: " with #{message_count} messages", else: ""))
          |> push_patch(to: ~p"/analytics?experiment_id=#{experiment_id}")

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
  def handle_event("update_message_count", %{"value" => value}, socket) do
    case Integer.parse(value) do
      {count, _} when count >= 0 ->
        {:noreply, assign(socket, :message_count, count)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_message_interval", %{"value" => value}, socket) do
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
    socket = load_experiment_data(socket)
    schedule_refresh()

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
        <h1 class="text-3xl font-bold text-gray-900 mb-2">Analytics Dashboard</h1>
        <p class="text-gray-600">Real-time cluster experiment monitoring</p>
      </div>

      <!-- Experiment History -->
      <%= if @experiment_history != [] do %>
        <div class="bg-white rounded-lg shadow p-6 mb-6">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-lg font-semibold">Experiment History</h3>
            <%= if @current_experiment && @viewing_mode == :historical do %>
              <button
                phx-click="clear_view"
                class="text-sm text-blue-600 hover:text-blue-800"
              >
                Clear Selection
              </button>
            <% end %>
          </div>

          <div class="overflow-x-auto">
            <table class="min-w-full table-auto">
              <thead>
                <tr class="bg-gray-50">
                  <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Experiment ID</th>
                  <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Started</th>
                  <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Duration</th>
                  <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Messages</th>
                  <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Acks</th>
                  <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for exp <- Enum.take(@experiment_history, 10) do %>
                  <tr class={[
                    "border-b hover:bg-gray-50",
                    if(@current_experiment == exp.id, do: "bg-blue-50", else: "")
                  ]}>
                    <td class="px-4 py-2 text-sm font-mono">{exp.id}</td>
                    <td class="px-4 py-2 text-sm">
                      <%= if exp.time_range do %>
                        {format_datetime(exp.time_range.start)}
                      <% else %>
                        <span class="text-gray-400">-</span>
                      <% end %>
                    </td>
                    <td class="px-4 py-2 text-sm">
                      <%= if exp.duration_seconds do %>
                        {exp.duration_seconds}s
                      <% else %>
                        <span class="text-gray-400">-</span>
                      <% end %>
                    </td>
                    <td class="px-4 py-2 text-sm">{exp.send_count}</td>
                    <td class="px-4 py-2 text-sm">{exp.ack_count}</td>
                    <td class="px-4 py-2 text-sm">
                      <button
                        phx-click="view_experiment"
                        phx-value-experiment_id={exp.id}
                        class="text-blue-600 hover:text-blue-800 text-sm"
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
            <div class="mt-4 text-sm text-gray-600 text-center">
              Showing 10 most recent experiments of {length(@experiment_history)} total
            </div>
          <% end %>
        </div>
      <% end %>

    <!-- Experiment Controls -->
      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <h3 class="text-lg font-semibold mb-4">Experiment Control</h3>

        <form phx-submit="start_aggregation" class="space-y-4">
          <!-- Experiment ID -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Experiment ID
            </label>
            <input
              type="text"
              name="experiment_id"
              placeholder="Enter experiment ID"
              value={@current_experiment}
              class="border rounded px-3 py-2 w-full"
              required
              disabled={@aggregation_status == :running}
            />
          </div>

          <!-- Message Sending Configuration -->
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">
                Number of Messages (0 = manual sending)
              </label>
              <input
                type="number"
                name="message_count"
                value={@message_count}
                min="0"
                max="1000"
                class="border rounded px-3 py-2 w-full"
                disabled={@aggregation_status == :running}
                phx-change="update_message_count"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">
                Message Interval (ms)
              </label>
              <input
                type="number"
                name="message_interval_ms"
                value={@message_interval_ms}
                min="100"
                max="60000"
                step="100"
                class="border rounded px-3 py-2 w-full"
                disabled={@aggregation_status == :running}
                phx-change="update_message_interval"
              />
            </div>
          </div>

          <!-- Action Buttons -->
          <div class="flex items-center gap-4">
            <button
              type="submit"
              class="bg-blue-500 text-white px-4 py-2 rounded hover:bg-blue-600 disabled:opacity-50 disabled:cursor-not-allowed"
              disabled={@aggregation_status == :running}
            >
              Start Experiment
            </button>

            <button
              type="button"
              phx-click="stop_aggregation"
              class="bg-red-500 text-white px-4 py-2 rounded hover:bg-red-600 disabled:opacity-50 disabled:cursor-not-allowed"
              disabled={@aggregation_status == :stopped}
            >
              Stop
            </button>

            <button
              type="button"
              phx-click="refresh_now"
              class="bg-gray-500 text-white px-4 py-2 rounded hover:bg-gray-600"
            >
              Refresh Now
            </button>
          </div>
        </form>

        <!-- Status Bar -->
        <div class="mt-4 flex flex-wrap items-center gap-4 pt-4 border-t">
          <div class="flex items-center gap-2">
            <span class="text-sm text-gray-600">Status:</span>
            <span class={[
              "px-2 py-1 rounded text-xs font-medium",
              if(@aggregation_status == :running,
                do: "bg-green-100 text-green-800",
                else: "bg-gray-100 text-gray-800"
              )
            ]}>
              {String.capitalize(to_string(@aggregation_status))}
            </span>
          </div>

          <%= if @message_progress do %>
            <div class="flex items-center gap-2">
              <span class="text-sm text-gray-600">Messages:</span>
              <span class="px-2 py-1 bg-blue-100 text-blue-800 rounded text-xs font-medium">
                {@message_progress.sent}/{@message_progress.total}
              </span>
              <%= if @message_progress.sent < @message_progress.total do %>
                <div class="w-32 bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-blue-600 h-2 rounded-full transition-all duration-300"
                    style={"width: #{Float.round(@message_progress.sent / @message_progress.total * 100, 1)}%"}
                  >
                  </div>
                </div>
              <% else %>
                <span class="text-xs text-green-600 font-medium">Complete</span>
              <% end %>
            </div>
          <% end %>

          <div class="flex items-center gap-2">
            <span class="text-sm text-gray-600">Refresh:</span>
            <select
              phx-change="set_refresh_interval"
              name="interval"
              class="border rounded px-2 py-1 text-sm"
            >
              <option value="1000" selected={@refresh_interval == 1000}>1s</option>
              <option value="5000" selected={@refresh_interval == 5000}>5s</option>
              <option value="10000" selected={@refresh_interval == 10000}>10s</option>
              <option value="30000" selected={@refresh_interval == 30000}>30s</option>
            </select>
          </div>

          <%= if @last_update do %>
            <div class="text-sm text-gray-600">
              Last update: {format_time(@last_update)}
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Experiment Summary -->
      <%= if @current_experiment do %>
        <div class="bg-white rounded-lg shadow p-6 mb-6">
          <h3 class="text-lg font-semibold mb-4">
            Experiment: {@current_experiment}
          </h3>

          <%= if @cluster_summary do %>
            <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4">
              <div class="text-center">
                <div class="text-2xl font-bold text-blue-600">{@cluster_summary.node_count || 0}</div>
                <div class="text-sm text-gray-600">Nodes</div>
              </div>
              <div class="text-center">
                <div class="text-2xl font-bold text-green-600">
                  {@cluster_summary.send_count || 0}
                </div>
                <div class="text-sm text-gray-600">Messages Sent</div>
              </div>
              <div class="text-center">
                <div class="text-2xl font-bold text-purple-600">
                  {@cluster_summary.ack_count || 0}
                </div>
                <div class="text-sm text-gray-600">Acknowledged</div>
              </div>
              <div class="text-center">
                <div class="text-2xl font-bold text-orange-600">
                  <%= if @cluster_summary.send_count && @cluster_summary.send_count > 0 && @cluster_summary.node_count > 1 do %>
                    <% expected_acks = @cluster_summary.send_count * @cluster_summary.node_count %>
                    {Float.round(@cluster_summary.ack_count / expected_acks * 100, 1)}%
                  <% else %>
                    0%
                  <% end %>
                </div>
                <div class="text-sm text-gray-600">Ack Rate</div>
              </div>
              <div class="text-center">
                <div class="text-2xl font-bold text-indigo-600">
                  {@cluster_summary.system_metrics_count || 0}
                </div>
                <div class="text-sm text-gray-600">Metrics</div>
              </div>
              <div class="text-center">
                <div class="text-2xl font-bold text-gray-600">
                  {@cluster_summary.topology_snapshots_count || 0}
                </div>
                <div class="text-sm text-gray-600">Snapshots</div>
              </div>
            </div>
          <% else %>
            <div class="text-gray-500 text-center py-8">
              No data available. Start aggregation to begin monitoring.
            </div>
          <% end %>
        </div>
        
    <!-- Active Nodes -->
        <div class="bg-white rounded-lg shadow p-6 mb-6">
          <h3 class="text-lg font-semibold mb-4">Active Nodes</h3>

          <%= if @active_nodes != [] do %>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <%= for node <- @active_nodes do %>
                <div class="border rounded p-3">
                  <div class="font-medium">{node.node_id}</div>
                  <div class="text-sm text-gray-600">
                    Region: {node.region || "Unknown"}
                  </div>
                  <%= if node.phoenix_port do %>
                    <div class="text-sm text-gray-600">
                      Port: {node.phoenix_port}
                    </div>
                  <% end %>
                  <%= if node.is_local do %>
                    <div class="text-xs bg-blue-100 text-blue-800 px-2 py-1 rounded mt-1 inline-block">
                      Local Node
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="text-gray-500 text-center py-4">
              No active nodes detected
            </div>
          <% end %>
        </div>
        
    <!-- Timing Statistics -->
        <div class="bg-white rounded-lg shadow p-6 mb-6">
          <h3 class="text-lg font-semibold mb-4">Message Timing Statistics</h3>

          <%= if @timing_stats != [] do %>
            <div class="overflow-x-auto">
              <table class="min-w-full table-auto">
                <thead>
                  <tr class="bg-gray-50">
                    <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Message ID</th>
                    <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Send Time</th>
                    <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Acks</th>
                    <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Min Latency</th>
                    <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Max Latency</th>
                    <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Avg Latency</th>
                    <th class="px-4 py-2 text-left text-sm font-medium text-gray-900">Nodes</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for stat <- @timing_stats do %>
                    <tr class="border-b">
                      <td class="px-4 py-2 text-sm font-mono">{stat.message_id}</td>
                      <td class="px-4 py-2 text-sm">{format_datetime(stat.send_time)}</td>
                      <td class="px-4 py-2 text-sm">{stat.ack_count}</td>
                      <td class="px-4 py-2 text-sm">
                        <%= if stat.min_latency_ms do %>
                          {stat.min_latency_ms}ms
                        <% else %>
                          <span class="text-gray-400">-</span>
                        <% end %>
                      </td>
                      <td class="px-4 py-2 text-sm">
                        <%= if stat.max_latency_ms do %>
                          {stat.max_latency_ms}ms
                        <% else %>
                          <span class="text-gray-400">-</span>
                        <% end %>
                      </td>
                      <td class="px-4 py-2 text-sm">
                        <%= if stat.avg_latency_ms do %>
                          {stat.avg_latency_ms}ms
                        <% else %>
                          <span class="text-gray-400">-</span>
                        <% end %>
                      </td>
                      <td class="px-4 py-2 text-sm">{length(stat.acknowledgments)}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="text-gray-500 text-center py-8">
              No timing statistics available
            </div>
          <% end %>
        </div>
        
    <!-- System Metrics Chart -->
        <div class="bg-white rounded-lg shadow p-6">
          <h3 class="text-lg font-semibold mb-4">System Metrics</h3>

          <%= if @system_metrics != [] do %>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <!-- Memory Usage -->
              <div>
                <h4 class="font-medium mb-2">Memory Usage (MB)</h4>
                <div class="space-y-2">
                  <%= for metric <- Enum.take(@system_metrics, 10) do %>
                    <div class="flex items-center justify-between text-sm">
                      <span class="text-gray-600">{metric.node_id}</span>
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
                      <span class="text-gray-600">{metric.node_id}</span>
                      <span class="font-medium">{metric.erlang_processes}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% else %>
            <div class="text-gray-500 text-center py-8">
              No system metrics available
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="bg-white rounded-lg shadow p-6 text-center">
          <h3 class="text-lg font-semibold mb-2">No Experiment Selected</h3>
          <p class="text-gray-600">Enter an experiment ID above to start monitoring</p>
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

      socket
      |> assign(:cluster_summary, cluster_summary)
      |> assign(:timing_stats, timing_stats)
      |> assign(:system_metrics, system_metrics)
      |> assign(:active_nodes, active_nodes)
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
end

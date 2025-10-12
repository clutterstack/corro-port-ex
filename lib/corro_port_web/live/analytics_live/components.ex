defmodule CorroPortWeb.AnalyticsLive.Components do
  @moduledoc """
  Phoenix Components for rendering analytics dashboard sections.

  Provides reusable components for:
  - Experiment controls (start/stop, configuration)
  - Experiment history table
  - Cluster summary statistics
  - Node performance tables
  - Active nodes grid
  - Timing statistics table
  - System metrics display
  - Chart containers
  """

  use Phoenix.Component
  import CorroPortWeb.AnalyticsLive.Helpers
  alias CorroPortWeb.AnalyticsLive.Charts.{Histogram, TimeSeries}
  alias CorroPortWeb.AnalyticsLive.DataLoader

  @doc """
  Renders the experiment history table showing past experiments.

  Displays up to 10 most recent experiments with:
  - Experiment ID
  - Start time and duration
  - Message and acknowledgment counts
  - View details button
  """
  attr :experiment_history, :list, required: true
  attr :current_experiment, :string, default: nil
  attr :viewing_mode, :atom, default: :current

  def experiment_history(assigns) do
    ~H"""
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
    """
  end

  @doc """
  Renders the experiment control panel with start/stop buttons and configuration.
  """
  attr :current_experiment, :string, default: nil
  attr :aggregation_status, :atom, required: true
  attr :message_count, :integer, required: true
  attr :message_interval_ms, :integer, required: true
  attr :message_progress, :map, default: nil
  attr :refresh_interval, :integer, required: true
  attr :last_update, :any, default: nil
  attr :transport_mode, :atom, default: :corrosion

  def experiment_controls(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-6">
      <div class="card-body">
        <h3 class="card-title text-lg mb-4">Experiment Control</h3>

        <!-- Transport Mode Selection (Outside Form) -->
        <div class="mb-4" id="transport-mode-section">
          <label class="block text-sm font-medium text-base-content mb-2">
            Message Transport
          </label>
          <div class="flex gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="transport_mode_display"
                value="corrosion"
                checked={@transport_mode == :corrosion}
                class="radio radio-primary"
                disabled={@aggregation_status == :running}
                phx-click="update_transport_mode"
                phx-value-transport_mode="corrosion"
              />
              <span class="text-base-content">Corrosion (Gossip)</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="transport_mode_display"
                value="pubsub"
                checked={@transport_mode == :pubsub}
                class="radio radio-primary"
                disabled={@aggregation_status == :running}
                phx-click="update_transport_mode"
                phx-value-transport_mode="pubsub"
              />
              <span class="text-base-content">PubSub (Direct)</span>
            </label>
          </div>
          <p class="text-xs text-base-content/60 mt-1" id="transport-mode-help">
            <%= if @transport_mode == :corrosion do %>
              Messages propagate via Corrosion's gossip protocol (database replication)
            <% else %>
              Messages propagate via Phoenix.PubSub (direct BEAM messaging)
            <% end %>
          </p>
        </div>

        <form phx-submit="start_aggregation" class="space-y-4" id="experiment-form">
          <!-- Hidden input to include transport_mode in form submission -->
          <input type="hidden" name="transport_mode" value={@transport_mode} />

          <!-- Experiment ID -->
          <div>
            <label class="block text-sm font-medium text-base-content mb-2">
              Experiment ID
            </label>
            <div phx-update="ignore" id="experiment-id-container">
              <input
                type="text"
                name="experiment_id"
                id="experiment_id_input"
                placeholder="Enter experiment ID"
                class="input input-bordered w-full"
                required
                disabled={@aggregation_status == :running}
              />
            </div>
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

          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/70">Transport:</span>
            <span class={[
              "badge",
              if(@transport_mode == :pubsub, do: "badge-info", else: "badge-neutral")
            ]}>
              {if @transport_mode == :pubsub, do: "PubSub", else: "Corrosion"}
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
    """
  end

  @doc """
  Renders the cluster summary statistics for the current experiment.
  """
  attr :experiment_id, :string, required: true
  attr :cluster_summary, :map, default: nil
  attr :active_nodes, :list, required: true
  attr :local_node_id, :string, required: true

  def experiment_summary(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-6">
      <div class="card-body">
        <h3 class="card-title text-lg mb-4">
          Experiment: {@experiment_id}
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
                {format_percentage(
                  DataLoader.ack_rate(@cluster_summary,
                    active_nodes: @active_nodes,
                    local_node_id: @local_node_id
                  )
                )}
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
    """
  end

  @doc """
  Renders the node performance statistics table showing RTT metrics per node.
  """
  attr :node_performance_stats, :list, required: true

  def node_performance_table(assigns) do
    ~H"""
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
                      <span class={latency_colour_class(node_stat.min_latency_ms)}>
                        {node_stat.min_latency_ms}ms
                      </span>
                    </td>
                    <td class="font-medium">
                      <span class={latency_colour_class(node_stat.avg_latency_ms)}>
                        {node_stat.avg_latency_ms}ms
                      </span>
                    </td>
                    <td>
                      <span class={latency_colour_class(node_stat.max_latency_ms)}>
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
    """
  end

  @doc """
  Renders the latency histogram chart with percentile markers.
  """
  attr :latency_histogram, :map, required: true

  def latency_histogram_chart(assigns) do
    ~H"""
    <%= if @latency_histogram && @latency_histogram.total_count > 0 do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-2">Latency Distribution</h3>
          <p class="text-sm text-base-content/70 mb-4">
            Distribution of round-trip times across all {@latency_histogram.total_count} acknowledgements
          </p>

          <!-- SVG Histogram -->
          <div class="w-full" style="height: 300px;">
            <Histogram.render_latency_histogram histogram={@latency_histogram} />
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
    """
  end

  @doc """
  Renders the RTT time series chart showing performance over time.
  """
  attr :rtt_time_series, :list, required: true

  def rtt_time_series_chart(assigns) do
    ~H"""
    <%= if @rtt_time_series != [] do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-2">RTT Over Time by Node</h3>
          <p class="text-sm text-base-content/70 mb-4">
            Response time trends showing if nodes slow down as the experiment progresses
          </p>

          <!-- SVG Time Series Plot -->
          <div class="w-full" style="height: 400px;">
            <TimeSeries.render_rtt_time_series rtt_time_series={@rtt_time_series} />
          </div>

          <div class="mt-4 text-sm text-base-content/70">
            Each line represents a different responding node. Look for upward trends that might indicate
            degradation due to load or gossip overhead.
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders the active nodes grid showing cluster membership.
  """
  attr :active_nodes, :list, required: true

  def active_nodes_grid(assigns) do
    ~H"""
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
    """
  end

  @doc """
  Renders the message timing statistics table.
  """
  attr :timing_stats, :list, required: true

  def timing_stats_table(assigns) do
    ~H"""
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
    """
  end

  @doc """
  Renders the system metrics display showing memory and process counts.
  """
  attr :system_metrics, :list, required: true

  def system_metrics(assigns) do
    ~H"""
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
    """
  end
end

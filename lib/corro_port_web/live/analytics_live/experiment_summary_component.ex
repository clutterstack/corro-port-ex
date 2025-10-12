defmodule CorroPortWeb.AnalyticsLive.ExperimentSummaryComponent do
  @moduledoc """
  Phoenix Component for displaying experiment cluster summary statistics.

  Shows high-level metrics for the current experiment including:
  - Node count
  - Messages sent
  - Acknowledgments received
  - Acknowledgment rate
  - System metrics count
  - Topology snapshots count
  """

  use Phoenix.Component
  import CorroPortWeb.AnalyticsLive.Helpers
  alias CorroPortWeb.AnalyticsLive.DataLoader

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
end

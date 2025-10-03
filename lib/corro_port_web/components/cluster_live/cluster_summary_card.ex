defmodule CorroPortWeb.Components.ClusterLive.ClusterSummaryCard do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders the cluster summary card with statistics and API info.
  """
  attr :summary_stats, :map, required: true
  attr :api_info, :map, required: false, default: nil

  def cluster_summary_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-sm">
          <.icon name="hero-server-stack" class="w-4 h-4 mr-2" /> Cluster Summary
        </h3>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <!-- DNS-Discovered Nodes -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">
              <span title={@summary_stats.dns.tooltip} class="cursor-help">
                DNS-Discovered Nodes ℹ️
              </span>
            </div>
            <div class={"stat-value text-lg flex items-center #{@summary_stats.dns.display.class}"}>
              {@summary_stats.dns.display.content}
            </div>
            <div class="stat-desc text-xs">
              {@summary_stats.dns.regions_count} regions
              <span class="text-base-content/50 ml-1">
                • {@summary_stats.dns.source_label}
              </span>
            </div>
          </div>

          <!-- CLI Active Members -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">
              <span title={@summary_stats.cli.tooltip} class="cursor-help">
                CLI Active Members ℹ️
              </span>
            </div>
            <div class={"stat-value text-lg flex items-center #{@summary_stats.cli.display.class}"}>
              {@summary_stats.cli.display.content}
            </div>
            <div class="stat-desc text-xs">
              {@summary_stats.cli.regions_count} regions
              <span class="text-base-content/50 ml-1">
                • {@summary_stats.cli.source_label}
              </span>
            </div>
          </div>

          <!-- Cluster Health -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">API Health</div>
            <div class={"stat-value text-lg #{@summary_stats.api_health.class}"}>
              {@summary_stats.api_health.content}
            </div>
            <div class="stat-desc text-xs">{@summary_stats.api_health.description}</div>
          </div>

          <!-- Message Activity -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">Messages</div>
            <div class="stat-value text-lg">{@summary_stats.messages_count}</div>
            <div class="stat-desc text-xs">in database</div>
          </div>
        </div>

        <!-- API Info Details -->
        <div :if={@api_info} class="mt-4 text-sm space-y-2">
          <div class="flex items-center justify-between">
            <strong>Total Active Nodes:</strong>
            <span class="font-semibold text-lg">
              {@api_info.total_active_nodes}
            </span>
          </div>

          <div class="flex items-center justify-between">
            <strong>Remote Members:</strong>
            <span>
              {@api_info.active_member_count}/{@api_info.member_count} active
            </span>
          </div>

          <div class="flex items-center justify-between">
            <strong>Tracked Peers:</strong>
            <span>{@api_info.peer_count}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end

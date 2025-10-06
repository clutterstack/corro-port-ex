defmodule CorroPortWeb.Components.ClusterLive.DataSourcesInfo do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders collapsible information about cluster data sources (DNS, CLI, API).
  """
  def data_sources_info(assigns) do
    ~H"""
    <details class="collapse collapse-arrow bg-base-200">
      <summary class="collapse-title text-sm font-medium">
        <.icon name="hero-information-circle" class="w-4 h-4 inline mr-2" /> About Data Sources
      </summary>
      <div class="collapse-content">
        <div class="grid md:grid-cols-3 gap-4 text-sm">
          <div class="card bg-base-100">
            <div class="card-body p-4">
              <h4 class="font-semibold flex items-center gap-2">
                <.icon name="hero-globe-alt" class="w-4 h-4" /> DNS Discovery
              </h4>
              <p class="text-xs text-base-content/70 mt-2">
                Queries DNS TXT records to find nodes that <strong>should exist</strong>
                based on infrastructure configuration.
              </p>
              <div class="text-xs mt-2 space-y-1">
                <div>
                  <strong>Query:</strong>
                  <code class="text-xs">vms.&#123;app_name&#125;.internal</code>
                </div>
                <div><strong>Returns:</strong> Expected node IDs and regions</div>
                <div><strong>Refresh:</strong> On-demand (OS DNS cache)</div>
              </div>
            </div>
          </div>

          <div class="card bg-base-100">
            <div class="card-body p-4">
              <h4 class="font-semibold flex items-center gap-2">
                <.icon name="hero-command-line" class="w-4 h-4" /> CLI Members
              </h4>
              <p class="text-xs text-base-content/70 mt-2">
                Executes <code>corro cluster members</code>
                to find Corrosion nodes <strong>actively participating</strong>
                in the gossip protocol.
              </p>
              <div class="text-xs mt-2 space-y-1">
                <div>
                  <strong>Command:</strong> <code class="text-xs">corro cluster members</code>
                </div>
                <div><strong>Returns:</strong> Active members with RTT, state, leader/follower</div>
                <div><strong>Refresh:</strong> Every 5 minutes + on-demand</div>
              </div>
            </div>
          </div>

          <div class="card bg-base-100">
            <div class="card-body p-4">
              <h4 class="font-semibold flex items-center gap-2">
                <.icon name="hero-server" class="w-4 h-4" /> Corrosion API
              </h4>
              <p class="text-xs text-base-content/70 mt-2">
                Queries the <strong>database-level cluster state</strong>
                from the Corrosion agent's API.
              </p>
              <div class="text-xs mt-2 space-y-1">
                <div><strong>Query:</strong> <code class="text-xs">__corro_members</code> table</div>
                <div><strong>Returns:</strong> Member counts, peers, system state</div>
                <div><strong>Refresh:</strong> On-demand</div>
              </div>
            </div>
          </div>
        </div>

        <div class="alert alert-info mt-4 text-xs">
          <.icon name="hero-light-bulb" class="w-4 h-4" />
          <div>
            <strong>Architecture Note:</strong>
            CorroPort runs as two layers: Corrosion agents (database/storage on ports 8081+) and Phoenix nodes (web UI on ports 4001+). Corrosion agents must be running before Phoenix nodes can start.
          </div>
        </div>
      </div>
    </details>
    """
  end
end

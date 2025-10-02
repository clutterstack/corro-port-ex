defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{DebugSection, NavTabs, CLIMembersTable, DNSNodesTable, MembersTable}
  alias CorroPortWeb.DisplayHelpers
  alias CorroPort.NodeConfig

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to CLI cluster data updates
      CorroPort.CLIClusterData.subscribe_active()
    end

    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000
    local_node_id = NodeConfig.get_corrosion_node_id()

    socket =
      socket
      |> assign(%{
        page_title: "Cluster Status",
        local_node_id: local_node_id,
        phoenix_port: phoenix_port,
        corro_api_port: CorroPort.ConnectionManager.get_corro_api_port()
      })
      |> fetch_all_data()

    {:ok, socket}
  end

  # Event handlers - unified refresh system

  def handle_event("refresh_all", _params, socket) do
    Logger.debug("ClusterLive: 🔄 Full refresh triggered")
    {:noreply, fetch_all_data(socket)}
  end

  def handle_event("refresh_expected", _params, socket) do
    socket = fetch_all_data(socket)
    {:noreply, put_flash(socket, :info, "DNS data refreshed")}
  end

  def handle_event("refresh_cli_members", _params, socket) do
    CorroPort.CLIClusterData.refresh_members()
    {:noreply, put_flash(socket, :info, "CLI member refresh initiated...")}
  end


  # Real-time updates from domain modules

  def handle_info({:active_members_updated, active_data}, socket) do
    Logger.debug("ClusterLive: Received active members update")

    # Recreate marker groups with updated active data
    marker_groups = create_region_groups(socket.assigns.expected_data, active_data, socket.assigns.local_node)

    socket = assign(socket, %{
      active_data: active_data,
      marker_groups: marker_groups
    })

    {:noreply, socket}
  end

  # Private functions

  defp fetch_all_data(socket) do
    # Fetch DNS data directly (no caching needed)
    expected_data = CorroPort.DNSLookup.get_expected_data()
    # Fetch from CLI cluster data (has its own caching)
    active_data = CorroPort.CLIClusterData.get_active_data()
    local_node = CorroPort.LocalNode.get_info()

    # Fetch cluster info directly from API, falling back to previous data on error
    conn = CorroPort.ConnectionManager.get_connection()
    previous_cluster_info = Map.get(socket.assigns, :cluster_info)

    {cluster_info, cluster_error} =
      case CorroClient.get_cluster_info(conn) do
        {:ok, info} -> {info, nil}
        {:error, reason} -> {previous_cluster_info, reason}
      end

    # Build system_data structure for DisplayHelpers compatibility
    system_data = %{
      cluster_info: cluster_info,
      database_info: nil,
      latest_messages: [],
      cache_status: %{
        last_updated: DateTime.utc_now(),
        error: cluster_error
      }
    }

    # Create marker groups for the FlyMapEx API
    marker_groups = create_region_groups(expected_data, active_data, local_node)

    assign(socket, %{
      # Data from clean domain modules
      expected_data: expected_data,
      active_data: active_data,
      system_data: system_data,
      local_node: local_node,
      cluster_info: cluster_info,

      # Computed marker groups for map display
      marker_groups: marker_groups,

      last_updated: DateTime.utc_now()
    })
    |> maybe_flash_cluster_error(cluster_error)
  end

  defp exclude_our_region(regions, our_region) do
    Enum.reject(regions, &(&1 == our_region))
  end

  defp maybe_flash_cluster_error(socket, nil) do
    Phoenix.LiveView.clear_flash(socket, :error)
  end

  defp maybe_flash_cluster_error(socket, error) do
    put_flash(socket, :error, "Failed to refresh __corro_members from Corrosion API. Showing last successful data. Reason: #{inspect(error)}")
  end

  defp create_region_groups(expected_data, active_data, local_node) do
    # Build marker groups for the FlyMapEx API
    groups = []

    # Our region (primary/local node)
    groups = if local_node.region != "unknown" do
      [%{nodes: [local_node.region], style_key: :primary, label: "Our Node"} | groups]
    else
      groups
    end

    # Active regions (excluding our region)
    active_regions = exclude_our_region(active_data.regions, local_node.region)
    groups = if !Enum.empty?(active_regions) do
      [%{nodes: active_regions, style_key: :active, label: "Active Regions"} | groups]
    else
      groups
    end

    # Expected regions (excluding our region)
    expected_regions = exclude_our_region(expected_data.regions, local_node.region)
    groups = if !Enum.empty?(expected_regions) do
      [%{nodes: expected_regions, style_key: :expected, label: "Expected Regions"} | groups]
    else
      groups
    end

    # Return groups in reverse order (since we prepended)
    Enum.reverse(groups)
  end

  def render(assigns) do
    # Pre-compute all display data using helpers
    dns_alert = DisplayHelpers.dns_alert_config(assigns.expected_data)
    cli_alert = DisplayHelpers.cli_alert_config(assigns.active_data)
    system_alert = DisplayHelpers.system_alert_config(assigns.system_data)

    summary_stats = DisplayHelpers.cluster_summary_stats(
      assigns.expected_data,
      assigns.active_data,
      assigns.system_data,
      assigns.expected_data.regions,
      assigns.active_data.regions
    )

    system_info = DisplayHelpers.system_info_details(assigns.system_data)
    cli_member_data = DisplayHelpers.build_cli_member_data(assigns.active_data)
    cli_error = DisplayHelpers.extract_cli_error(assigns.active_data)
    cache_status = DisplayHelpers.all_cache_status(assigns.expected_data, assigns.active_data, assigns.system_data)

    assigns = assign(assigns, %{
      dns_alert: dns_alert,
      cli_alert: cli_alert,
      system_alert: system_alert,
      summary_stats: summary_stats,
      system_info: system_info,
      cli_member_data: cli_member_data,
      cli_error: cli_error,
      cache_status: cache_status
    })

    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:cluster} />

      <.header>
        Corrosion Cluster Status
        <:subtitle>
          <div class="flex items-center gap-4">
            <span>Comprehensive cluster health and node connectivity monitoring</span>
          </div>
        </:subtitle>
        <:actions>
          <div class="flex gap-2">
            <!-- Per-domain refresh buttons using helper functions -->
            <.button
              phx-click="refresh_expected"
              class={DisplayHelpers.refresh_button_class(@expected_data)}
            >
              <.icon name="hero-globe-alt" class="w-3 h-3 mr-1" />
              DNS
              <span :if={DisplayHelpers.show_warning?(@expected_data)} class="ml-1">⚠</span>
            </.button>

            <.button
              phx-click="refresh_cli_members"
              class={DisplayHelpers.refresh_button_class(@active_data)}
            >
              <.icon name="hero-command-line" class="w-3 h-3 mr-1" />
              CLI
              <span :if={DisplayHelpers.show_warning?(@active_data)} class="ml-1">⚠</span>
            </.button>

            <.button phx-click="refresh_all" class="btn btn-sm">
              <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh All
            </.button>
          </div>
        </:actions>
      </.header>

      <!-- Error alerts using pre-computed configurations -->
      <.error_alert :if={@dns_alert} config={@dns_alert} />
      <.error_alert :if={@cli_alert} config={@cli_alert} />
      <.error_alert :if={@system_alert} config={@system_alert} />

      <!-- About Data Sources (collapsible) -->
      <details class="collapse collapse-arrow bg-base-200">
        <summary class="collapse-title text-sm font-medium">
          <.icon name="hero-information-circle" class="w-4 h-4 inline mr-2" />
          About Data Sources
        </summary>
        <div class="collapse-content">
          <div class="grid md:grid-cols-3 gap-4 text-sm">
            <div class="card bg-base-100">
              <div class="card-body p-4">
                <h4 class="font-semibold flex items-center gap-2">
                  <.icon name="hero-globe-alt" class="w-4 h-4" />
                  DNS Discovery
                </h4>
                <p class="text-xs text-base-content/70 mt-2">
                  Queries DNS TXT records to find nodes that <strong>should exist</strong> based on infrastructure configuration.
                </p>
                <div class="text-xs mt-2 space-y-1">
                  <div><strong>Query:</strong> <code class="text-xs">vms.&#123;app_name&#125;.internal</code></div>
                  <div><strong>Returns:</strong> Expected node IDs and regions</div>
                  <div><strong>Refresh:</strong> On-demand (OS DNS cache)</div>
                </div>
              </div>
            </div>

            <div class="card bg-base-100">
              <div class="card-body p-4">
                <h4 class="font-semibold flex items-center gap-2">
                  <.icon name="hero-command-line" class="w-4 h-4" />
                  CLI Members
                </h4>
                <p class="text-xs text-base-content/70 mt-2">
                  Executes <code>corro cluster members</code> to find Corrosion nodes <strong>actively participating</strong> in the gossip protocol.
                </p>
                <div class="text-xs mt-2 space-y-1">
                  <div><strong>Command:</strong> <code class="text-xs">corro cluster members</code></div>
                  <div><strong>Returns:</strong> Active members with RTT, state, leader/follower</div>
                  <div><strong>Refresh:</strong> Every 5 minutes + on-demand</div>
                </div>
              </div>
            </div>

            <div class="card bg-base-100">
              <div class="card-body p-4">
                <h4 class="font-semibold flex items-center gap-2">
                  <.icon name="hero-server" class="w-4 h-4" />
                  Corrosion API
                </h4>
                <p class="text-xs text-base-content/70 mt-2">
                  Queries the <strong>database-level cluster state</strong> from the Corrosion agent's API.
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
              <strong>Architecture Note:</strong> CorroPort runs as two layers: Corrosion agents (database/storage on ports 8081+) and Phoenix nodes (web UI on ports 4001+). Corrosion agents must be running before Phoenix nodes can start.
            </div>
          </div>
        </div>
      </details>

      <!-- Enhanced World Map with Regions -->
      <FlyMapEx.render
        marker_groups={@marker_groups}
        theme={:monitoring}
      />

      <!-- DNS-Discovered Nodes Table -->
      <DNSNodesTable.display expected_data={@expected_data} />

      <!-- CLI Members Display with clean data structure -->
      <CLIMembersTable.display
        cli_member_data={@cli_member_data}
        cli_error={@cli_error}
      />

      <!-- Corrosion API (__corro_members) table entries -->
      <MembersTable.cluster_members_table :if={@cluster_info} cluster_info={@cluster_info} />


      <!-- Enhanced Cluster Summary using pre-computed stats -->
      <.cluster_summary
        summary_stats={@summary_stats}
        system_info={@system_info} />

      <!-- Debug Section with clean data -->
      <DebugSection.debug_section
        cluster_info={@system_data.cluster_info}
        node_messages={@system_data.latest_messages}
      />

      <!-- Cache status indicators using pre-computed status -->
      <.cache_status_display cache_status={@cache_status} />

      <!-- Last Updated -->
      <div class="text-xs text-base-content/70 text-center">
        Page updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end

  # Helper components extracted from inline template logic

  defp error_alert(%{config: nil} = assigns), do: ~H""
  defp error_alert(assigns) do
    ~H"""
    <div class={@config.class}>
      <.icon name={@config.icon} class="w-5 h-5" />
      <div>
        <div class="font-semibold">{@config.title}</div>
        <div class="text-sm">{@config.message}</div>
      </div>
    </div>
    """
  end

  defp cluster_summary(assigns) do
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
              <span title={@summary_stats.expected.tooltip} class="cursor-help">
                DNS-Discovered Nodes ℹ️
              </span>
            </div>
            <div class={"stat-value text-lg flex items-center #{@summary_stats.expected.display.class}"}>
              {@summary_stats.expected.display.content}
            </div>
            <div class="stat-desc text-xs">
              {@summary_stats.expected.regions_count} regions
              <span class="text-base-content/50 ml-1">
                • {@summary_stats.expected.source_label}
              </span>
            </div>
          </div>

          <!-- CLI Active Members -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">
              <span title={@summary_stats.active.tooltip} class="cursor-help">
                CLI Active Members ℹ️
              </span>
            </div>
            <div class={"stat-value text-lg flex items-center #{@summary_stats.active.display.class}"}>
              {@summary_stats.active.display.content}
            </div>
            <div class="stat-desc text-xs">
              {@summary_stats.active.regions_count} regions
              <span class="text-base-content/50 ml-1">
                • {@summary_stats.active.source_label}
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

        <!-- System Info Details -->
        <div :if={@system_info} class="mt-4 text-sm space-y-2">
          <div class="flex items-center justify-between">
            <strong>Total Active Nodes:</strong>
            <span class="font-semibold text-lg">
              {@system_info.total_active_nodes}
            </span>
          </div>

          <div class="flex items-center justify-between">
            <strong>Remote Members:</strong>
            <span>
              {@system_info.active_member_count}/{@system_info.member_count} active
            </span>
          </div>

          <div class="flex items-center justify-between">
            <strong>Tracked Peers:</strong>
            <span>{@system_info.peer_count}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp cache_status_display(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4">
        <h4 class="text-sm font-semibold mb-3 flex items-center gap-2">
          <.icon name="hero-clock" class="w-4 h-4" />
          Data Source Status
        </h4>
        <div class="grid md:grid-cols-3 gap-4 text-xs">
          <div class="flex items-start gap-2">
            <.icon name="hero-globe-alt" class="w-4 h-4 mt-0.5 text-primary" />
            <div>
              <div class="font-semibold">DNS Discovery</div>
              <div class="text-base-content/70">{@cache_status.dns}</div>
            </div>
          </div>

          <div class="flex items-start gap-2">
            <.icon name="hero-command-line" class="w-4 h-4 mt-0.5 text-secondary" />
            <div>
              <div class="font-semibold">CLI Members</div>
              <div class="text-base-content/70">{@cache_status.cli}</div>
            </div>
          </div>

          <div class="flex items-start gap-2">
            <.icon name="hero-server" class="w-4 h-4 mt-0.5 text-accent" />
            <div>
              <div class="font-semibold">Corrosion API</div>
              <div class="text-base-content/70">{@cache_status.system}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end

defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{MembersTable, DebugSection, NavTabs, CLIMembersTable}
  alias CorroPortWeb.DisplayHelpers
  alias CorroPort.NodeConfig

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to all clean domain modules
      CorroPort.NodeDiscovery.subscribe()
      CorroPort.ClusterMembership.subscribe()
      CorroPort.MessagePropagation.subscribe()
      CorroPort.ClusterSystemInfo.subscribe()
    end

    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000
    local_node_id = NodeConfig.get_corrosion_node_id()

    socket =
      assign(socket, %{
        page_title: "Cluster Status",
        local_node_id: local_node_id,
        phoenix_port: phoenix_port,
        corro_api_port: CorroPort.CorrosionClient.get_corro_api_port(),

        # Data from clean domain modules
        expected_data: nil,
        active_data: nil,
        ack_data: nil,
        system_data: nil,
        local_node: CorroPort.LocalNode.get_info(),

        # Computed regions for map display
        expected_regions: [],
        active_regions: [],
        ack_regions: [],
        our_regions: [],

        # General state
        last_updated: nil
      })

    {:ok, fetch_all_data(socket)}
  end

  # Event handlers - unified refresh system

  def handle_event("refresh_all", _params, socket) do
    Logger.debug("ClusterLive: 🔄 Full refresh triggered")
    {:noreply, fetch_all_data(socket)}
  end

  def handle_event("refresh_expected", _params, socket) do
    CorroPort.NodeDiscovery.refresh_cache()
    {:noreply, put_flash(socket, :info, "DNS cache refresh initiated...")}
  end

  def handle_event("refresh_active", _params, socket) do
    CorroPort.ClusterMembership.refresh_cache()
    {:noreply, put_flash(socket, :info, "CLI member refresh initiated...")}
  end

  def handle_event("refresh_system", _params, socket) do
    CorroPort.ClusterSystemInfo.refresh_cache()
    {:noreply, put_flash(socket, :info, "System info refresh initiated...")}
  end

  def handle_event("send_message", _params, socket) do
    case CorroPort.MessagePropagation.send_message("Test message from cluster view") do
      {:ok, _message_data} ->
        socket =
          socket
          |> assign(:ack_regions, [])  # Reset ack regions for new message
          |> put_flash(:info, "Message sent! Tracking acknowledgments...")
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send: #{DisplayHelpers.format_error_reason(reason)}")}
    end
  end

  def handle_event("reset_tracking", _params, socket) do
    case CorroPort.MessagePropagation.reset_tracking() do
      :ok ->
        Logger.info("ClusterLive: ✅ Message tracking reset successfully")

        socket =
          socket
          |> assign(:ack_regions, [])  # Clear violet regions immediately
          |> put_flash(:info, "Message tracking reset - all nodes are now orange (expected)")

        {:noreply, socket}

      {:error, error} ->
        Logger.warning("ClusterLive: ❌ Failed to reset tracking: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to reset tracking: #{DisplayHelpers.format_error_reason(error)}")}
    end
  end

  # Real-time updates from domain modules

  def handle_info({:expected_nodes_updated, expected_data}, socket) do
    Logger.debug("ClusterLive: Received expected nodes update")

    new_expected_regions = exclude_our_region(expected_data.regions, socket.assigns.local_node.region)

    socket = assign(socket, %{
      expected_data: expected_data,
      expected_regions: new_expected_regions
    })

    {:noreply, socket}
  end

  def handle_info({:active_members_updated, active_data}, socket) do
    Logger.debug("ClusterLive: Received active members update")

    new_active_regions = exclude_our_region(active_data.regions, socket.assigns.local_node.region)

    socket = assign(socket, %{
      active_data: active_data,
      active_regions: new_active_regions
    })

    {:noreply, socket}
  end

  def handle_info({:ack_status_updated, ack_data}, socket) do
    Logger.debug("ClusterLive: Received ack status update")

    socket = assign(socket, %{
      ack_data: ack_data,
      ack_regions: ack_data.regions
    })

    {:noreply, socket}
  end

  def handle_info({:cluster_system_updated, system_data}, socket) do
    Logger.debug("ClusterLive: Received cluster system update")

    socket = assign(socket, :system_data, system_data)

    {:noreply, socket}
  end

  # Private functions

  defp fetch_all_data(socket) do
    # Fetch from all clean domain modules
    expected_data = CorroPort.NodeDiscovery.get_expected_data()
    active_data = CorroPort.ClusterMembership.get_active_data()
    ack_data = CorroPort.MessagePropagation.get_ack_data()
    system_data = CorroPort.ClusterSystemInfo.get_system_data()
    local_node = CorroPort.LocalNode.get_info()

    assign(socket, %{
      # Data from clean domain modules
      expected_data: expected_data,
      active_data: active_data,
      ack_data: ack_data,
      system_data: system_data,
      local_node: local_node,

      # Computed regions for map display (excluding our region)
      expected_regions: exclude_our_region(expected_data.regions, local_node.region),
      active_regions: exclude_our_region(active_data.regions, local_node.region),
      ack_regions: ack_data.regions,
      our_regions: [local_node.region],

      last_updated: DateTime.utc_now()
    })
  end

  defp exclude_our_region(regions, our_region) do
    Enum.reject(regions, &(&1 == our_region))
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
      assigns.expected_regions,
      assigns.active_regions
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
              phx-click="refresh_active"
              class={DisplayHelpers.refresh_button_class(@active_data)}
            >
              <.icon name="hero-command-line" class="w-3 h-3 mr-1" />
              CLI
              <span :if={DisplayHelpers.show_warning?(@active_data)} class="ml-1">⚠</span>
            </.button>

            <.button
              phx-click="refresh_system"
              class={DisplayHelpers.refresh_button_class(@system_data, "btn btn-xs")}
            >
              <.icon name="hero-server" class="w-3 h-3 mr-1" />
              System
              <span :if={@system_data.cache_status.error} class="ml-1">⚠</span>
            </.button>

            <.button phx-click="reset_tracking" class="btn btn-warning btn-outline btn-sm">
              <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Reset
            </.button>

            <.button phx-click="send_message" variant="primary" class="btn-sm">
              <.icon name="hero-paper-airplane" class="w-3 h-3 mr-1" /> Send
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

      <!-- Enhanced World Map with Regions -->
      <CorroPortWeb.WorldMapCard.world_map_card
        active_regions={@active_regions}
        our_regions={@our_regions}
        expected_regions={@expected_regions}
        ack_regions={@ack_regions}
        show_acknowledgment_progress={true}
        cli_members_stale={DisplayHelpers.has_error?(@active_data)}
      />

      <!-- CLI Members Display with clean data structure -->
      <CLIMembersTable.display
        cli_member_data={@cli_member_data}
        cli_error={@cli_error}
      />

      <!-- System Members Table using clean data -->
      <MembersTable.cluster_members_table cluster_info={@system_data.cluster_info} />

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
          <!-- Expected Nodes -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">Expected Nodes</div>
            <div class={"stat-value text-lg flex items-center #{@summary_stats.expected.display.class}"}>
              {@summary_stats.expected.display.content}
            </div>
            <div class="stat-desc text-xs">{@summary_stats.expected.regions_count} regions</div>
          </div>

          <!-- Active Members -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">Active Members</div>
            <div class={"stat-value text-lg flex items-center #{@summary_stats.active.display.class}"}>
              {@summary_stats.active.display.content}
            </div>
            <div class="stat-desc text-xs">{@summary_stats.active.regions_count} regions</div>
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
    <div class="flex gap-4 text-xs text-base-content/70">
      <div>
        <strong>DNS Cache:</strong>
        {@cache_status.dns}
      </div>

      <div>
        <strong>CLI Cache:</strong>
        {@cache_status.cli}
      </div>

      <div>
        <strong>System Cache:</strong>
        {@cache_status.system}
      </div>
    </div>
    """
  end
end

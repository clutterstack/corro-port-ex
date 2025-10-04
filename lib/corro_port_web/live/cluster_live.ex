defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.Components.ClusterLive.{
    DebugSection,
    CLIMembersTable,
    DNSNodesTable,
    MembersTable,
    ClusterHeader,
    DataSourcesInfo,
    ClusterSummaryCard
  }

  alias CorroPortWeb.{
    NavTabs,
    DisplayHelpers,
    CacheStatusCard
  }

  alias CorroPort.NodeConfig

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to CLI cluster data updates
      CorroPort.CLIClusterData.subscribe_cli()
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

  # Event handlers - targeted refresh system

  def handle_event("refresh_all", _params, socket) do
    Logger.debug("ClusterLive: 🔄 Full refresh triggered")
    {:noreply, fetch_all_data(socket)}
  end

  def handle_event("refresh_dns", _params, socket) do
    socket = refresh_dns_data(socket)
    {:noreply, put_flash(socket, :info, "DNS data refreshed")}
  end

  def handle_event("refresh_cli", _params, socket) do
    CorroPort.CLIClusterData.refresh_members()
    {:noreply, put_flash(socket, :info, "CLI member refresh initiated...")}
  end

  def handle_event("refresh_api", _params, socket) do
    socket = refresh_api_data(socket)
    {:noreply, put_flash(socket, :info, "API data refreshed")}
  end


  # Real-time updates from domain modules

  def handle_info({:cli_members_updated, cli_data}, socket) do
    Logger.debug("ClusterLive: Received CLI members update")

    # Recreate marker groups with updated CLI data
    marker_groups = create_region_groups(socket.assigns.dns_data, cli_data, socket.assigns.local_node)

    socket = assign(socket, %{
      cli_data: cli_data,
      marker_groups: marker_groups
    })

    {:noreply, socket}
  end

  # Private functions

  defp fetch_all_data(socket) do
    # Fetch DNS data directly (no caching needed)
    dns_data = CorroPort.DNSLookup.get_dns_data()
    # Fetch from CLI cluster data (has its own caching)
    cli_data = CorroPort.CLIClusterData.get_cli_data()
    local_node = CorroPort.LocalNode.get_info()

    # Fetch cluster info directly from API, falling back to previous data on error
    conn = CorroPort.ConnectionManager.get_connection()
    previous_cluster_info = Map.get(socket.assigns, :cluster_info)

    {cluster_info, cluster_error} =
      case CorroClient.get_cluster_info(conn) do
        {:ok, info} -> {info, nil}
        {:error, reason} -> {previous_cluster_info, reason}
      end

    # Build api_data structure for DisplayHelpers compatibility
    api_data = %{
      cluster_info: cluster_info,
      cache_status: %{
        last_updated: DateTime.utc_now(),
        error: cluster_error
      }
    }

    # Create marker groups for the FlyMapEx API
    marker_groups = create_region_groups(dns_data, cli_data, local_node)

    assign(socket, %{
      # Data from clean domain modules
      dns_data: dns_data,
      cli_data: cli_data,
      api_data: api_data,
      local_node: local_node,
      cluster_info: cluster_info,

      # Computed marker groups for map display
      marker_groups: marker_groups,

      last_updated: DateTime.utc_now()
    })
    |> maybe_flash_cluster_error(cluster_error)
  end

  defp refresh_dns_data(socket) do
    # Fetch only DNS data
    dns_data = CorroPort.DNSLookup.get_dns_data()

    # Recompute marker groups (depends on dns_data, cli_data, local_node)
    marker_groups = create_region_groups(dns_data, socket.assigns.cli_data, socket.assigns.local_node)

    assign(socket, %{
      dns_data: dns_data,
      marker_groups: marker_groups,
      last_updated: DateTime.utc_now()
    })
  end

  defp refresh_api_data(socket) do
    # Fetch cluster info from Corrosion API
    conn = CorroPort.ConnectionManager.get_connection()
    previous_cluster_info = socket.assigns.cluster_info

    {cluster_info, cluster_error} =
      case CorroClient.get_cluster_info(conn) do
        {:ok, info} -> {info, nil}
        {:error, reason} -> {previous_cluster_info, reason}
      end

    # Build api_data structure
    api_data = %{
      cluster_info: cluster_info,
      cache_status: %{
        last_updated: DateTime.utc_now(),
        error: cluster_error
      }
    }

    assign(socket, %{
      api_data: api_data,
      cluster_info: cluster_info,
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

  defp create_region_groups(dns_data, cli_data, local_node) do
    # Build marker groups for the FlyMapEx API

    # Our region (primary/local node)
    local_node = if local_node.region != "unknown" do
      %{nodes: [local_node.region], style: :local, label: "Our Node"}
    else
      %{}
    end

    # CLI regions
    cli_regions = if !Enum.empty?(cli_data.regions) do
      %{nodes: cli_data.regions, style: :cli, label: "Active Regions by CLI"}
    else
      %{}
    end

    # DNS regions (excluding our region)
    dns_regions = if !Enum.empty?(dns_data.regions) do
    %{nodes: dns_data.regions, style: :dns, label: "App Regions by DNS"}
    else
      %{}
    end

    [
      dns_regions,
      cli_regions,
      local_node
    ]
  end

  def render(assigns) do
    # Pre-compute all display data using helpers
    dns_alert = DisplayHelpers.dns_alert_config(assigns.dns_data)
    cli_alert = DisplayHelpers.cli_alert_config(assigns.cli_data)
    api_alert = DisplayHelpers.api_alert_config(assigns.api_data)

    summary_stats = DisplayHelpers.cluster_summary_stats(
      assigns.dns_data,
      assigns.cli_data,
      assigns.api_data,
      assigns.dns_data.regions,
      assigns.cli_data.regions
    )

    cli_member_data = DisplayHelpers.build_cli_member_data(assigns.cli_data)
    cli_error = DisplayHelpers.extract_cli_error(assigns.cli_data)
    cache_status = DisplayHelpers.all_cache_status(assigns.dns_data, assigns.cli_data, assigns.api_data)

    assigns = assign(assigns, %{
      dns_alert: dns_alert,
      cli_alert: cli_alert,
      api_alert: api_alert,
      summary_stats: summary_stats,
      cli_member_data: cli_member_data,
      cli_error: cli_error,
      cache_status: cache_status
    })

    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:cluster} />

      <!-- Header with refresh all button -->
      <ClusterHeader.cluster_header />

      <!-- Error alerts using pre-computed configurations -->
      <.error_alert :if={@dns_alert} config={@dns_alert} />
      <.error_alert :if={@cli_alert} config={@cli_alert} />
      <.error_alert :if={@api_alert} config={@api_alert} />

      <!-- Enhanced World Map with Regions -->
      <FlyMapEx.render
        marker_groups={@marker_groups}
        theme={:monitoring}
      />

      <!-- Enhanced Cluster Summary using pre-computed stats -->
      <ClusterSummaryCard.cluster_summary_card
        summary_stats={@summary_stats}
      />

      <!-- DNS-Discovered Nodes Table -->
      <DNSNodesTable.display dns_data={@dns_data} />

      <!-- CLI Members Display with clean data structure -->
      <CLIMembersTable.display
        cli_data={@cli_data}
        cli_member_data={@cli_member_data}
        cli_error={@cli_error}
      />

      <!-- Corrosion API (__corro_members) table entries -->
      <MembersTable.cluster_members_table :if={@cluster_info} cluster_info={@cluster_info} api_data={@api_data} />

      <!-- About Data Sources (collapsible) -->
      <DataSourcesInfo.data_sources_info />

      <!-- Cache status indicators using pre-computed status -->
      <CacheStatusCard.cache_status_card cache_status={@cache_status} />

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

end

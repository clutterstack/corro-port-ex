defmodule CorroPortWeb.IndexLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{
    NavTabs,
    PropagationHeader,
    ErrorAlerts,
    CacheStatus
  }

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to CLI cluster data and acknowledgment updates
      CorroPort.CLIClusterData.subscribe_cli()
      Phoenix.PubSub.subscribe(CorroPort.PubSub, "ack_events")
    end

    socket = fetch_all_data(socket)
    {:ok, socket}
  end

  # Event handlers - per-domain refresh
  def handle_event("refresh_dns", _params, socket) do
    socket = fetch_all_data(socket)
    {:noreply, put_flash(socket, :info, "DNS data refreshed")}
  end

  def handle_event("refresh_cli", _params, socket) do
    CorroPort.CLIClusterData.refresh_members()
    {:noreply, put_flash(socket, :info, "CLI member refresh initiated...")}
  end

  def handle_event("send_message", _params, socket) do
    case CorroPort.MessagesAPI.send_and_track_message("Test propagation message") do
      {:ok, _message_data} ->
        socket =
          socket
          |> assign(:ack_regions, [])  # Reset ack regions for new message
          |> put_flash(:info, "Message sent! Tracking acknowledgments...")
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send: #{format_error(reason)}")}
    end
  end

  def handle_event("reset_tracking", _params, socket) do
    case CorroPort.AckTracker.reset_tracking() do
      :ok ->
        Logger.info("IndexLive: ✅ Message tracking reset successfully")

        socket =
          socket
          |> assign(:ack_regions, [])  # Clear violet regions immediately
          |> put_flash(:info, "Message tracking reset - all nodes are now orange (expected)")

        {:noreply, socket}

      {:error, error} ->
        Logger.warning("IndexLive: ❌ Failed to reset tracking: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to reset tracking: #{format_error(error)}")}
    end
  end

  def handle_event("refresh_all", _params, socket) do
    Logger.debug("IndexLive: 🔄 Manual refresh triggered")
    {:noreply, fetch_all_data(socket)}
  end

  # Real-time updates from domain modules
  def handle_info({:cli_members_updated, cli_data}, socket) do
    Logger.debug("IndexLive: Received CLI members update")

    new_cli_regions = exclude_our_region(cli_data.regions, socket.assigns.local_node.region)
    marker_groups = create_region_groups(socket.assigns.dns_data, cli_data, socket.assigns.ack_data, socket.assigns.local_node)

    socket = assign(socket, %{
      cli_data: cli_data,
      cli_regions: new_cli_regions,
      marker_groups: marker_groups
    })

    {:noreply, socket}
  end

  def handle_info({:ack_update, ack_data}, socket) do
    Logger.debug("IndexLive: Received ack status update")

    marker_groups = create_region_groups(socket.assigns.dns_data, socket.assigns.cli_data, ack_data, socket.assigns.local_node)

    socket = assign(socket, %{
      ack_data: ack_data,
      ack_regions: ack_data.regions,
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
    ack_data = CorroPort.AckTracker.get_status()
    local_node = CorroPort.LocalNode.get_info()

    marker_groups = create_region_groups(dns_data, cli_data, ack_data, local_node)

    assign(socket, %{
      page_title: "Geographic Distribution",

      # Raw data with embedded success/error states
      dns_data: dns_data,
      cli_data: cli_data,
      ack_data: ack_data,
      local_node: local_node,

      # Computed regions for map display (excluding our region)
      dns_regions: exclude_our_region(dns_data.regions, local_node.region),
      cli_regions: exclude_our_region(cli_data.regions, local_node.region),
      ack_regions: ack_data.regions,
      our_regions: [local_node.region],

      # Marker groups for FlyMapEx
      marker_groups: marker_groups,

      last_updated: DateTime.utc_now()
    })
  end

  defp exclude_our_region(regions, our_region) do
    Enum.reject(regions, &(&1 == our_region))
  end

  defp format_error(reason) do
    case reason do
      :dns_failed -> "DNS lookup failed"
      :cli_timeout -> "CLI command timed out"
      {:cli_failed, _} -> "CLI command failed"
      {:parse_failed, _} -> "Failed to parse CLI output"
      :service_unavailable -> "Service unavailable"
      {:tracking_failed, _} -> "Failed to start tracking"
      _ -> "#{inspect(reason)}"
    end
  end

  defp create_region_groups(dns_data, cli_data, ack_data, local_node) do
    # Build marker groups for the FlyMapEx API
    groups = []

    # Our region (primary/local node)
    groups = if local_node.region != "unknown" do
      [%{nodes: [local_node.region], style_key: :primary, label: "Our Node"} | groups]
    else
      groups
    end

    # CLI regions (excluding our region)
    cli_regions = exclude_our_region(cli_data.regions, local_node.region)
    groups = if !Enum.empty?(cli_regions) do
      [%{nodes: cli_regions, style_key: :active, label: "CLI Active Regions"} | groups]
    else
      groups
    end

    # DNS regions (excluding our region)
    dns_regions = exclude_our_region(dns_data.regions, local_node.region)
    groups = if !Enum.empty?(dns_regions) do
      [%{nodes: dns_regions, style_key: :expected, label: "DNS Expected Regions"} | groups]
    else
      groups
    end

    # Acknowledged regions (includes all that acknowledged, including our region)
    groups = if !Enum.empty?(ack_data.regions) do
      [%{nodes: ack_data.regions, style_key: :acknowledged, label: "Acknowledged Messages"} | groups]
    else
      groups
    end

    # Return groups in reverse order (since we prepended)
    Enum.reverse(groups)
  end

  defp format_regions_display(regions, empty_message) do
    filtered_regions = Enum.reject(regions, &(&1 == "" or &1 == "unknown"))

    if filtered_regions != [] do
      " (#{Enum.join(filtered_regions, ", ")})"
    else
      " #{empty_message}"
    end
  end

  defp dns_empty_message do
    case Application.get_env(:corro_port, :node_config)[:environment] do
      :prod -> "(none found)"
      _ -> "(none; no DNS in dev)"
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:propagation} />

      <!-- Page Header with Actions -->
      <PropagationHeader.propagation_header
        dns_data={@dns_data}
        cli_data={@cli_data}
      />

      <!-- Error Alerts -->
      <ErrorAlerts.error_alerts
        dns_data={@dns_data}
        cli_data={@cli_data}
      />

      <!-- Enhanced World Map with Regions -->
      <FlyMapEx.render
        marker_groups={@marker_groups}
      />

      <!-- Cache Status Indicators -->
      <CacheStatus.cache_status
        dns_data={@dns_data}
        cli_data={@cli_data}
      />

      <!-- Last Updated -->
      <div class="text-xs text-base-content/70 text-center">
        Page updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end
end

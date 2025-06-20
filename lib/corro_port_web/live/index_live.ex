defmodule CorroPortWeb.IndexLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{
    NavTabs,
    PropagationHeader,
    ErrorAlerts,
    PropagationProgress,
    PropagationStats,
    CacheStatus
  }

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to the clean domain modules
      CorroPort.NodeDiscovery.subscribe()
      CorroPort.ClusterMembership.subscribe()
      CorroPort.MessagePropagation.subscribe()
    end

    socket = fetch_all_data(socket)
    {:ok, socket}
  end

  # Event handlers - per-domain refresh
  def handle_event("refresh_expected", _params, socket) do
    CorroPort.NodeDiscovery.refresh_cache()
    {:noreply, put_flash(socket, :info, "DNS cache refresh initiated...")}
  end

  def handle_event("refresh_active", _params, socket) do
    CorroPort.ClusterMembership.refresh_cache()
    {:noreply, put_flash(socket, :info, "CLI member refresh initiated...")}
  end

  def handle_event("send_message", _params, socket) do
    case CorroPort.MessagePropagation.send_message("Test propagation message") do
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
    case CorroPort.MessagePropagation.reset_tracking() do
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
  def handle_info({:expected_nodes_updated, expected_data}, socket) do
    Logger.debug("IndexLive: Received expected nodes update")

    new_expected_regions = exclude_our_region(expected_data.regions, socket.assigns.local_node.region)

    socket = assign(socket, %{
      expected_data: expected_data,
      expected_regions: new_expected_regions
    })

    {:noreply, socket}
  end

  def handle_info({:active_members_updated, active_data}, socket) do
    Logger.debug("IndexLive: Received active members update")

    new_active_regions = exclude_our_region(active_data.regions, socket.assigns.local_node.region)

    socket = assign(socket, %{
      active_data: active_data,
      active_regions: new_active_regions
    })

    {:noreply, socket}
  end

  def handle_info({:ack_status_updated, ack_data}, socket) do
    Logger.debug("IndexLive: Received ack status update")

    socket = assign(socket, %{
      ack_data: ack_data,
      ack_regions: ack_data.regions
    })

    {:noreply, socket}
  end

  # Private functions

  defp fetch_all_data(socket) do
    # Fetch from clean domain modules - explicit success/error handling
    expected_data = CorroPort.NodeDiscovery.get_expected_data()
    active_data = CorroPort.ClusterMembership.get_active_data()
    ack_data = CorroPort.MessagePropagation.get_ack_data()
    local_node = CorroPort.LocalNode.get_info()

    assign(socket, %{
      page_title: "Geographic Distribution",

      # Raw data with embedded success/error states
      expected_data: expected_data,
      active_data: active_data,
      ack_data: ack_data,
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

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:propagation} />

      <!-- Page Header with Actions -->
      <PropagationHeader.propagation_header
        expected_data={@expected_data}
        active_data={@active_data}
      />

      <!-- Error Alerts -->
      <ErrorAlerts.error_alerts
        expected_data={@expected_data}
        active_data={@active_data}
      />

      <!-- Enhanced World Map with Regions -->
      <div class="card bg-base-100">
        <div class="card-body">
          <div class="rounded-lg border">
            <CorroPortWeb.WorldMap.world_map_svg
              regions={@active_regions}
              our_regions={@our_regions}
              expected_regions={@expected_regions}
              ack_regions={@ack_regions}
            />
          </div>

          <!-- Progress and Legend -->
          <PropagationProgress.propagation_progress
            expected_regions={@expected_regions}
            active_regions={@active_regions}
            ack_regions={@ack_regions}
            our_regions={@our_regions}
          />
        </div>
      </div>

      <!-- Summary Stats -->
      <PropagationStats.propagation_stats
        expected_data={@expected_data}
        active_data={@active_data}
        expected_regions={@expected_regions}
        active_regions={@active_regions}
        ack_regions={@ack_regions}
      />

      <!-- Cache Status Indicators -->
      <CacheStatus.cache_status
        expected_data={@expected_data}
        active_data={@active_data}
      />

      <!-- Last Updated -->
      <div class="text-xs text-base-content/70 text-center">
        Page updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end
end

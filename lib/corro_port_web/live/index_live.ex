defmodule CorroPortWeb.IndexLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{ClusterCards, RegionHelper, NavTabs}
  alias CorroPort.{DNSNodeDiscovery, AckTracker, ClusterMemberStore}

  def mount(_params, _session, socket) do
    # Subscribe to acknowledgment updates and cluster member updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CorroPort.PubSub, AckTracker.get_pubsub_topic())
      ClusterMemberStore.subscribe()
    end

    socket =
      assign(socket, %{
        page_title: "Geographic Distribution",

        # Clear node sets based on different sources
        # From DNS
        expected_nodes: [],
        # Regions from DNS nodes
        expected_regions: [],
        # From CLI store
        active_members: [],
        # Regions from CLI members
        active_regions: [],
        # Our local region
        our_regions: [],
        # Regions that acknowledged latest message
        ack_regions: [],

        # CLI state tracking (now from centralized store)
        # Error from CLI store
        cli_error: nil,
        # Whether CLI data is old due to error
        cli_members_stale: false,
        # Data from centralized store
        cli_member_data: nil,

        # Keep basic cluster info for debugging
        cluster_info: nil,

        # General state
        error: nil,
        last_updated: nil,
        ack_status: nil
      })

    {:ok, fetch_cluster_data(socket)}
  end

  # Event handlers

  def handle_event("send_message", _params, socket) do
    case CorroPortWeb.ClusterLive.MessageHandler.send_message() do
      {:ok, success_message, message_data} ->
        Logger.debug("IndexLive: ✅ Message sent successfully: #{inspect(message_data)}")

        # Track this message for acknowledgment monitoring
        track_message_data = %{
          pk: message_data.pk,
          timestamp: message_data.timestamp,
          node_id: message_data.node_id
        }

        AckTracker.track_latest_message(track_message_data)
        Logger.debug("IndexLive: Now tracking message #{message_data.pk} for acknowledgments")

        socket =
          socket
          # Reset ack regions since we're tracking a new message
          |> assign(:ack_regions, [])
          |> put_flash(:info, success_message)

        {:noreply, socket}

      {:error, error} ->
        socket = put_flash(socket, :error, "Failed to send message: #{error}")
        {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket) do
    Logger.debug("IndexLive: 🔄 Manual refresh triggered")
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_event("refresh_dns_cache", _params, socket) do
    Logger.debug("IndexLive: 🌐 DNS cache refresh triggered")

    DNSNodeDiscovery.refresh_cache()

    socket =
      socket
      |> fetch_cluster_data()
      |> put_flash(:info, "DNS cache refreshed")

    {:noreply, socket}
  end

  def handle_event("reset_tracking", _params, socket) do
    case AckTracker.reset_tracking() do
      :ok ->
        Logger.info("IndexLive: ✅ Message tracking reset successfully")

        socket =
          socket
          # Clear the violet regions immediately
          |> assign(:ack_regions, [])
          |> put_flash(:info, "Message tracking reset - all nodes are now orange (expected)")

        {:noreply, socket}

      {:error, error} ->
        Logger.warning("IndexLive: ❌ Failed to reset tracking: #{inspect(error)}")
        socket = put_flash(socket, :error, "Failed to reset tracking: #{inspect(error)}")
        {:noreply, socket}
    end
  end

  # Handle cluster member updates from centralized store
  def handle_info({:cluster_members_updated, cli_member_data}, socket) do
    Logger.debug("IndexLive: 🔄 Received cluster members update from store")

    socket =
      socket
      |> assign(:cli_member_data, cli_member_data)
      |> update_regions_from_cli_data(cli_member_data)

    {:noreply, socket}
  end

  # Handle acknowledgment updates
  def handle_info({:ack_update, ack_status}, socket) do
    Logger.debug("IndexLive: Received acknowledgment update")

    ack_regions = RegionHelper.extract_ack_regions(ack_status)

    socket = assign(socket, %{ack_regions: ack_regions, ack_status: ack_status})
    {:noreply, socket}
  end

  # Private functions

  defp fetch_cluster_data(socket) do
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data()

    # Extract region data using the new helper
    {expected_regions, active_regions, our_regions} =
      RegionHelper.extract_cluster_regions(updates)

    # Get current acknowledgment status
    ack_status = AckTracker.get_status()
    ack_regions = RegionHelper.extract_ack_regions(ack_status)

    # Get CLI member data from store
    cli_member_data = ClusterMemberStore.get_members()

    # Determine if CLI data is stale
    cli_members_stale = !is_nil(updates.cli_error) && updates.active_members != []

    assign(socket, %{
      expected_nodes: updates.expected_nodes,
      expected_regions: expected_regions,
      active_members: updates.active_members,
      active_regions: active_regions,
      our_regions: our_regions,
      ack_regions: ack_regions,
      ack_status: ack_status,
      cluster_info: updates.cluster_info,
      cli_error: updates.cli_error,
      cli_members_stale: cli_members_stale,
      cli_member_data: cli_member_data,
      error: updates.error,
      last_updated: updates.last_updated
    })
  end

  defp update_regions_from_cli_data(socket, cli_member_data) do
    # Recompute active regions when CLI data updates
    active_regions =
      cli_member_data.members
      |> Enum.map(&CorroPort.AckTracker.member_to_node_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&CorroPort.CorrosionParser.extract_region_from_node_id/1)
      |> Enum.reject(&(&1 == "unknown"))
      |> Enum.uniq()

    # Remove our region from active regions
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    our_region = CorroPort.CorrosionParser.extract_region_from_node_id(local_node_id)
    active_regions = Enum.reject(active_regions, &(&1 == our_region))

    assign(socket, %{
      active_members: cli_member_data.members,
      active_regions: active_regions,
      cli_error: cli_member_data.last_error,
      cli_members_stale: cli_member_data.status == :error && cli_member_data.members != []
    })
  end

  defp dns_regions_display(expected_regions) do
    case Application.get_env(:corro_port, :node_config)[:environment] do
      :prod ->
        Logger.debug("dns_regions_display: we're in prod")

        if expected_regions != [] do
          {expected_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")}
        else
          "(none found)"
        end

      :dev ->
        Logger.debug("dns_regions_display: we're in dev")
        "(none; no DNS in dev)"
    end
  end

 def render(assigns) do
    ~H"""
    <div class="space-y-6">
    <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:propagation} />
      <.header>
      <.icon name="hero-radio" class="w-5 h-5 mr-2" /> DB change propagation
      <:subtitle>
        <div class="flex items-center gap-4">
          <span>Click "Send Message." Markers change colour as nodes confirm they've received the update.</span>
        </div>
      </:subtitle>
      <:actions>
        <.button :if={Application.get_env(:corro_port, :node_config) == :prod} phx-click="refresh_dns_cache" class="btn btn-xs btn-outline">
          <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh DNS
        </.button>
        <.button
          phx-click="reset_tracking"
          class="btn btn-warning btn-outline"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Reset Tracking
        </.button>
        <.button phx-click="send_message" variant="primary">
          <.icon name="hero-paper-airplane" class="w-4 h-4 mr-2" /> Send Message
        </.button>
      </:actions>
    </.header>

      <ClusterCards.error_alerts error={@error} />

      <!-- CLI Error Alert -->
      <div :if={@cli_error} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">CLI Data Issue</div>
          <div class="text-sm">
            <%= case @cli_error do %>
              <% {:cli_error, :timeout} -> %>
                CLI command timed out after 15 seconds
              <% {:cli_error, reason} -> %>
                CLI command failed: #{inspect(reason)}
              <% {:parse_error, _reason} -> %>
                CLI command succeeded but output couldn't be parsed
              <% {:service_unavailable, msg} -> %>
                {msg}
              <% _ -> %>
                CLI issue: #{inspect(@cli_error)}
            <% end %>
            <%= if @cli_members_stale do %>
              - Showing stale active member data
            <% end %>
          </div>
        </div>
      </div>

      <!-- Enhanced World Map with Regions -->
      <CorroPortWeb.WorldMapCard.world_map_card
        active_regions={@active_regions}
        our_regions={@our_regions}
        expected_regions={@expected_regions}
        ack_regions={@ack_regions}
        show_acknowledgment_progress={true}
        cli_members_stale={@cli_members_stale}
      />

      <!-- Summary Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Expected Nodes</div>
          <div class="stat-value text-2xl">{length(@expected_nodes)}</div>
          <div class="stat-desc">{length(@expected_regions)} regions</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Active Members</div>
          <div class="stat-value text-2xl flex items-center">
            {length(@active_members)}
            <span :if={@cli_members_stale} class="badge badge-warning badge-xs ml-2">stale</span>
          </div>
          <div class="stat-desc">{length(@active_regions)} regions</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Acknowledged</div>
          <div class="stat-value text-2xl">{length(@ack_regions)}</div>
          <div class="stat-desc">regions responded</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Coverage</div>
          <div class="stat-value text-2xl">
            <%= if length(@expected_regions) > 0 do %>
              {round(length(@ack_regions) / length(@expected_regions) * 100)}%
            <% else %>
              0%
            <% end %>
          </div>
          <div class="stat-desc">acknowledgment rate</div>
        </div>
      </div>

      <!-- Last Updated -->
      <div :if={@last_updated} class="text-xs text-base-content/70 text-center">
        Last updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end
end

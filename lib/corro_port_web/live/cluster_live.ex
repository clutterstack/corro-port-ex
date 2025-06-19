defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{ClusterCards, MembersTable, DebugSection, NavTabs, CLIMembersTable}
  alias CorroPort.{DNSNodeDiscovery, AckTracker, ClusterMemberStore, NodeConfig}

  # 5 minutes refresh interval
  @refresh_interval 300_000

  def mount(_params, _session, socket) do
    # Subscribe to acknowledgment updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CorroPort.PubSub, AckTracker.get_pubsub_topic())
      # Subscribe to cluster member updates
      ClusterMemberStore.subscribe()
    end

    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000
    local_node_id = NodeConfig.get_corrosion_node_id()

    socket =
      assign(socket, %{
        page_title: "Cluster Status",
        local_node_id: local_node_id,

        # NEW: Clear node sets based on different sources
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

        # Keep these for the existing components that still need them
        phoenix_port: phoenix_port,
        corro_api_port: CorroPort.CorrosionClient.get_corro_api_port(),
        refresh_interval: @refresh_interval,

        # General state
        error: nil,
        last_updated: nil,
        ack_status: nil
      })

    {:ok, fetch_cluster_data(socket)}
  end

  # Event handlers

  def handle_event("refresh", _params, socket) do
    Logger.debug("ClusterLive: 🔄 Manual refresh triggered")
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_event("refresh_cli_members", _params, socket) do
    Logger.debug("ClusterLive: 🔧 Manual CLI members refresh triggered")

    ClusterMemberStore.refresh_members()

    socket = put_flash(socket, :info, "CLI member refresh initiated...")
    {:noreply, socket}
  end

  def handle_event("refresh_dns_cache", _params, socket) do
    Logger.debug("ClusterLive: 🌐 DNS cache refresh triggered")

    DNSNodeDiscovery.refresh_cache()

    socket =
      socket
      |> fetch_cluster_data()
      |> put_flash(:info, "DNS cache refreshed")

    {:noreply, socket}
  end

  # Handle cluster member updates from centralized store
  def handle_info({:cluster_members_updated, cli_member_data}, socket) do
    Logger.debug("ClusterLive: 🔄 Received cluster members update from store")

    socket =
      socket
      |> assign(:cli_member_data, cli_member_data)
      |> update_regions_from_cli_data(cli_member_data)

    {:noreply, socket}
  end

  # Handle acknowledgment updates
  def handle_info({:ack_update, ack_status}, socket) do
    Logger.debug("ClusterLive: Received acknowledgment update")

    ack_regions = extract_ack_regions(ack_status)

    {:noreply, assign(socket, :ack_regions, ack_regions)}
  end

  # Private functions

  defp fetch_cluster_data(socket) do
    # For ClusterLive, we need the version with messages for the messages table
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data_with_messages()

    # Extract region data using the new helper
    {expected_regions, active_regions, our_regions} =
      CorroPortWeb.RegionHelper.extract_cluster_regions(updates)

    # Get current acknowledgment status
    ack_status = CorroPort.AckTracker.get_status()
    ack_regions = CorroPortWeb.RegionHelper.extract_ack_regions(ack_status)

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
      # Only ClusterLive gets this
      node_messages: updates.node_messages,
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
    our_region =
      CorroPort.CorrosionParser.extract_region_from_node_id(socket.assigns.local_node_id)

    active_regions = Enum.reject(active_regions, &(&1 == our_region))

    assign(socket, %{
      active_members: cli_member_data.members,
      active_regions: active_regions,
      cli_error: cli_member_data.last_error,
      cli_members_stale: cli_member_data.status == :error && cli_member_data.members != []
    })
  end

  defp extract_ack_regions(ack_status) do
    ack_status
    |> Map.get(:acknowledgments, [])
    |> Enum.map(fn ack ->
      CorroPort.CorrosionParser.extract_region_from_node_id(ack.node_id)
    end)
    |> Enum.reject(&(&1 == "unknown"))
    |> Enum.uniq()
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
      <NavTabs.nav_tabs active={:cluster} />

      <ClusterCards.cluster_header />

      <ClusterCards.error_alerts error={@error} />

      <!-- Enhanced World Map with Regions -->
      <CorroPortWeb.WorldMapCard.world_map_card
        active_regions={@active_regions}
        our_regions={@our_regions}
        expected_regions={@expected_regions}
        ack_regions={@ack_regions}
        cli_members_stale={@cli_members_stale}
      />

      <CLIMembersTable.display
        cli_member_data={@cli_member_data}
        cli_error={@cli_error}
      />

      <MembersTable.cluster_members_table cluster_info={@cluster_info} />

      <ClusterCards.cluster_summary_card
        local_node_id={@local_node_id}
        cluster_info={@cluster_info}
        node_messages={@node_messages}
        last_updated={@last_updated}
        phoenix_port={@phoenix_port}
        corro_api_port={@corro_api_port}
        refresh_interval={@refresh_interval}
        error={@error}
      />

      <DebugSection.debug_section
        cluster_info={@cluster_info}
        node_messages={@node_messages}
      />
    </div>
    """
  end
end

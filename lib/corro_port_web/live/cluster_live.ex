defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{ClusterCards, MembersTable, DebugSection, NavTabs}
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
      expected_nodes: [],        # From DNS
      expected_regions: [],      # Regions from DNS nodes
      active_members: [],        # From CLI store
      active_regions: [],        # Regions from CLI members
      our_regions: [],          # Our local region
      ack_regions: [],          # Regions that acknowledged latest message

      # CLI state tracking (now from centralized store)
      cli_error: nil,           # Error from CLI store
      cli_members_stale: false, # Whether CLI data is old due to error
      cli_member_data: nil,     # Data from centralized store

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
    Logger.debug("ClusterLive: 🤝 Received acknowledgment update")

    ack_regions = extract_ack_regions(ack_status)

    {:noreply, assign(socket, :ack_regions, ack_regions)}
  end

  # Private functions

  defp fetch_cluster_data(socket) do
    # For ClusterLive, we need the version with messages for the messages table
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data_with_messages()

    # Extract region data using the new helper
    {expected_regions, active_regions, our_regions} = CorroPortWeb.RegionHelper.extract_cluster_regions(updates)

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
      node_messages: updates.node_messages,  # Only ClusterLive gets this
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
    our_region = CorroPort.CorrosionParser.extract_region_from_node_id(socket.assigns.local_node_id)
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

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:cluster} />

      <ClusterCards.cluster_header />

      <ClusterCards.error_alerts error={@error} />

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

          <div class="text-sm text-base-content/70 space-y-2">
            <div class="flex items-center">
              <!-- Our node (yellow) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ffdc66;">
              </span>
              Our node
              <%= if @our_regions != [] do %>
                ({@our_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")})
              <% else %>
                (region unknown)
              <% end %>
            </div>

            <div class="flex items-center">
              <!-- Active other nodes (blue) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #77b5fe;">
              </span>
              Other active nodes
              <%= if @active_regions != [] do %>
                ({@active_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")})
                <%= if @cli_members_stale do %>
                  <span class="badge badge-warning badge-xs ml-2">stale</span>
                <% end %>
              <% else %>
                (none active)
              <% end %>
            </div>

            <div class="flex items-center">
              <!-- Expected nodes from DNS (orange) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ff8c42;">
              </span>
              Expected nodes (DNS)
              <%= if @expected_regions != [] do %>
                ({@expected_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")})
              <% else %>
                (none found)
              <% end %>
            </div>

            <div class="flex items-center">
              <!-- Acknowledged nodes (plasma violet) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #9d4edd;">
              </span>
              Acknowledged latest message
              <%= if @ack_regions != [] do %>
                ({@ack_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")})
              <% else %>
                (none yet)
              <% end %>
            </div>


          </div>
        </div>
      </div>

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

      <!-- CLI Members Section -->
      <div class="card bg-base-100">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h3 class="card-title">
              <.icon name="hero-command-line" class="w-5 h-5 mr-2" /> CLI Cluster Members
            </h3>
            <div class="flex gap-2">
              <.button phx-click="refresh_cli_members" class="btn btn-primary btn-sm">
                <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" />
                Refresh CLI Data
              </.button>
              <span :if={@cli_member_data && @cli_member_data.status == :fetching} class="flex items-center text-sm">
                <div class="loading loading-spinner loading-sm mr-2"></div>
                Fetching...
              </span>
            </div>
          </div>

          <!-- CLI Status Info -->
          <div :if={@cli_member_data} class="mb-4">
            <div class="flex items-center gap-4 text-sm">
              <div class="flex items-center gap-2">
                <span class="font-semibold">Status:</span>
                <span class={cli_status_badge_class(@cli_member_data.status)}>
                  {format_cli_status(@cli_member_data.status)}
                </span>
              </div>
              <div :if={@cli_member_data.last_updated}>
                <span class="font-semibold">Last Updated:</span>
                <span class="text-xs">{Calendar.strftime(@cli_member_data.last_updated, "%H:%M:%S")}</span>
              </div>
              <div>
                <span class="font-semibold">Members:</span>
                <span>{@cli_member_data.member_count}</span>
              </div>
            </div>
          </div>

          <!-- Error Display -->
          <div :if={@cli_error} class="alert alert-warning mb-4">
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
                    Unknown CLI error: #{inspect(@cli_error)}
                <% end %>
              </div>
            </div>
          </div>

          <!-- CLI Results -->
          <div :if={@cli_member_data && @cli_member_data.members != []} class="space-y-4">
            <div class="alert alert-success">
              <.icon name="hero-check-circle" class="w-5 h-5" />
              <span>Found {length(@cli_member_data.members)} cluster members via CLI</span>
            </div>

            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Address</th>
                    <th>Status</th>
                    <th>Cluster ID</th>
                    <th>Ring</th>
                    <th>RTT Stats</th>
                    <th>Last Sync</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={member <- @cli_member_data.members}>
                    <td class="font-mono text-xs">
                      {member["display_id"]}
                    </td>
                    <td class="font-mono text-sm">
                      {member["display_addr"]}
                    </td>
                    <td>
                      <span class={member["display_status_class"]}>
                        {member["display_status"]}
                      </span>
                    </td>
                    <td>{member["display_cluster_id"]}</td>
                    <td>{member["display_ring"]}</td>
                    <td class="text-xs">
                      <div>Avg: {member["display_rtt_avg"]}ms</div>
                      <div>Samples: {member["display_rtt_count"]}</div>
                    </td>
                    <td class="text-xs">
                      {member["display_last_sync"]}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Empty State -->
          <div :if={@cli_member_data && @cli_member_data.members == [] && !@cli_error} class="alert alert-info">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span>No cluster members found - this appears to be a single node setup</span>
          </div>

          <!-- Loading State -->
          <div :if={!@cli_member_data || @cli_member_data.status == :initializing} class="text-center py-4">
            <div class="loading loading-spinner loading-lg mb-2"></div>
            <div class="text-sm text-base-content/70">
              Initializing CLI member data...
            </div>
          </div>
        </div>
      </div>

      <MembersTable.cluster_members_table cluster_info={@cluster_info} />

      <DebugSection.debug_section
        cluster_info={@cluster_info}
        node_messages={@node_messages}
      />
    </div>
    """
  end

  # Helper functions for CLI status display

  defp cli_status_badge_class(status) do
    base = "badge badge-sm"

    case status do
      :ok -> "#{base} badge-success"
      :fetching -> "#{base} badge-info"
      :error -> "#{base} badge-error"
      :unavailable -> "#{base} badge-warning"
      :initializing -> "#{base} badge-neutral"
      _ -> "#{base} badge-neutral"
    end
  end

  defp format_cli_status(status) do
    case status do
      :ok -> "Active"
      :fetching -> "Fetching"
      :error -> "Error"
      :unavailable -> "Unavailable"
      :initializing -> "Starting"
      _ -> "Unknown"
    end
  end
end

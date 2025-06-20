defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{ClusterCards, MembersTable, DebugSection, NavTabs, CLIMembersTable}
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
        {:noreply, put_flash(socket, :error, "Failed to send: #{format_error(reason)}")}
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
        {:noreply, put_flash(socket, :error, "Failed to reset tracking: #{format_error(error)}")}
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

  defp format_error(reason) do
    case reason do
      :dns_failed -> "DNS lookup failed"
      :cli_timeout -> "CLI command timed out"
      {:cli_failed, _} -> "CLI command failed"
      {:parse_failed, _} -> "Failed to parse CLI output"
      :service_unavailable -> "Service unavailable"
      {:tracking_failed, _} -> "Failed to start tracking"
      {:cluster_api_failed, _} -> "Cluster API connection failed"
      {:fetch_exception, _} -> "System data fetch failed"
      _ -> "#{inspect(reason)}"
    end
  end

  def render(assigns) do
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
            <!-- Per-domain refresh buttons -->
            <.button
              phx-click="refresh_expected"
              class={[
                "btn btn-xs",
                if(match?({:error, _}, @expected_data.nodes), do: "btn-error", else: "btn-outline")
              ]}
            >
              <.icon name="hero-globe-alt" class="w-3 h-3 mr-1" />
              DNS
              <span :if={match?({:error, _}, @expected_data.nodes)} class="ml-1">⚠</span>
            </.button>

            <.button
              phx-click="refresh_active"
              class={[
                "btn btn-xs",
                if(match?({:error, _}, @active_data.members), do: "btn-error", else: "btn-outline")
              ]}
            >
              <.icon name="hero-command-line" class="w-3 h-3 mr-1" />
              CLI
              <span :if={match?({:error, _}, @active_data.members)} class="ml-1">⚠</span>
            </.button>

            <.button
              phx-click="refresh_system"
              class={[
                "btn btn-xs",
                if(@system_data.cache_status.error, do: "btn-error", else: "btn-outline")
              ]}
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

      <!-- Error alerts for each domain -->
      <div :if={match?({:error, reason}, @expected_data.nodes)} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">DNS Discovery Failed</div>
          <div class="text-sm">
            Error: #{format_error(reason)} - Expected regions may be incomplete
          </div>
        </div>
      </div>

      <div :if={match?({:error, reason}, @active_data.members)} class="alert alert-error">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">CLI Data Failed</div>
          <div class="text-sm">
            Error: {format_error(reason)} - Active member list may be stale
          </div>
        </div>
      </div>

      <div :if={@system_data.cache_status.error} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">System Data Issue</div>
          <div class="text-sm">
            Error: {format_error(@system_data.cache_status.error)} - Cluster info may be incomplete
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
        cli_members_stale={match?({:error, _}, @active_data.members)}
      />

      <!-- CLI Members Display with clean data structure -->
      <CLIMembersTable.display
        cli_member_data={build_cli_member_data_for_component(@active_data)}
        cli_error={extract_cli_error(@active_data)}
      />

      <!-- System Members Table using clean data -->
      <MembersTable.cluster_members_table cluster_info={@system_data.cluster_info} />

      <!-- Enhanced Cluster Summary -->
      <div class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title text-sm">
            <.icon name="hero-server-stack" class="w-4 h-4 mr-2" /> Cluster Summary
          </h3>

          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <!-- Expected Nodes -->
            <div class="stat bg-base-100 rounded-lg">
              <div class="stat-title text-xs">Expected Nodes</div>
              <div class="stat-value text-lg flex items-center">
                <%= case @expected_data.nodes do %>
                  <% {:ok, nodes} -> %>
                    {length(nodes)}
                  <% {:error, _} -> %>
                    <span class="text-error">?</span>
                <% end %>
              </div>
              <div class="stat-desc text-xs">{length(@expected_regions)} regions</div>
            </div>

            <!-- Active Members -->
            <div class="stat bg-base-100 rounded-lg">
              <div class="stat-title text-xs">Active Members</div>
              <div class="stat-value text-lg flex items-center">
                <%= case @active_data.members do %>
                  <% {:ok, members} -> %>
                    {length(members)}
                  <% {:error, _} -> %>
                    <span class="text-error">?</span>
                <% end %>
              </div>
              <div class="stat-desc text-xs">{length(@active_regions)} regions</div>
            </div>

            <!-- Cluster Health -->
            <div class="stat bg-base-100 rounded-lg">
              <div class="stat-title text-xs">API Health</div>
              <div class="stat-value text-lg">
                <%= if @system_data.cluster_info do %>
                  <span class="text-success">✓</span>
                <% else %>
                  <span class="text-error">✗</span>
                <% end %>
              </div>
              <div class="stat-desc text-xs">
                <%= if @system_data.cluster_info do %>
                  connected
                <% else %>
                  failed
                <% end %>
              </div>
            </div>

            <!-- Message Activity -->
            <div class="stat bg-base-100 rounded-lg">
              <div class="stat-title text-xs">Messages</div>
              <div class="stat-value text-lg">{length(@system_data.latest_messages)}</div>
              <div class="stat-desc text-xs">in database</div>
            </div>
          </div>

          <!-- System Info Details -->
          <div :if={@system_data.cluster_info} class="mt-4 text-sm space-y-2">
            <div class="flex items-center justify-between">
              <strong>Total Active Nodes:</strong>
              <span class="font-semibold text-lg">
                {Map.get(@system_data.cluster_info, "total_active_nodes", 0)}
              </span>
            </div>

            <div class="flex items-center justify-between">
              <strong>Remote Members:</strong>
              <span>
                {Map.get(@system_data.cluster_info, "active_member_count", 0)}/{Map.get(
                  @system_data.cluster_info,
                  "member_count",
                  0
                )} active
              </span>
            </div>

            <div class="flex items-center justify-between">
              <strong>Tracked Peers:</strong>
              <span>{Map.get(@system_data.cluster_info, "peer_count", 0)}</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Debug Section with clean data -->
      <DebugSection.debug_section
        cluster_info={@system_data.cluster_info}
        node_messages={@system_data.latest_messages}
      />

      <!-- Cache status indicators -->
      <div class="flex gap-4 text-xs text-base-content/70">
        <div>
          <strong>DNS Cache:</strong>
          <%= case @expected_data.cache_status do %>
            <% %{last_updated: nil} -> %>
              Never loaded
            <% %{last_updated: updated, error: nil} -> %>
              Updated {Calendar.strftime(updated, "%H:%M:%S")}
            <% %{last_updated: updated, error: error} -> %>
              Failed at {Calendar.strftime(updated, "%H:%M:%S")} ({format_error(error)})
          <% end %>
        </div>

        <div>
          <strong>CLI Cache:</strong>
          <%= case @active_data.cache_status do %>
            <% %{last_updated: nil} -> %>
              Never loaded
            <% %{last_updated: updated, error: nil} -> %>
              Updated {Calendar.strftime(updated, "%H:%M:%S")}
            <% %{last_updated: updated, error: error} -> %>
              Failed at {Calendar.strftime(updated, "%H:%M:%S")} ({format_error(error)})
          <% end %>
        </div>

        <div>
          <strong>System Cache:</strong>
          <%= case @system_data.cache_status do %>
            <% %{last_updated: nil} -> %>
              Never loaded
            <% %{last_updated: updated, error: nil} -> %>
              Updated {Calendar.strftime(updated, "%H:%M:%S")}
            <% %{last_updated: updated, error: error} -> %>
              Failed at {Calendar.strftime(updated, "%H:%M:%S")} ({format_error(error)})
          <% end %>
        </div>
      </div>

      <!-- Last Updated -->
      <div class="text-xs text-base-content/70 text-center">
        Page updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end

  # Helper functions to bridge between new data structure and existing components

  defp build_cli_member_data_for_component(active_data) do
    # Convert the new active_data structure to what CLIMembersTable expects
    case active_data.members do
      {:ok, members} ->
        %{
          members: members,
          member_count: length(members),
          status: :ok,
          last_updated: active_data.cache_status.last_updated,
          last_error: nil
        }

      {:error, reason} ->
        %{
          members: [],
          member_count: 0,
          status: :error,
          last_updated: active_data.cache_status.last_updated,
          last_error: reason
        }
    end
  end

  defp extract_cli_error(active_data) do
    case active_data.members do
      {:ok, _} -> nil
      {:error, reason} -> reason
    end
  end
end

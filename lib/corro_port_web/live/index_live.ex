defmodule CorroPortWeb.IndexLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.NavTabs

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

  defp dns_regions_display(expected_regions) do
    case Application.get_env(:corro_port, :node_config)[:environment] do
      :prod ->
        if expected_regions != [] do
          expected_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")
        else
          "(none found)"
        end
      _ ->
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
          <div class="flex gap-2">
            <!-- Per-domain refresh buttons -->
            <.button
              phx-click="refresh_expected"
              class={[
                "btn btn-sm",
                if(match?({:error, _}, @expected_data.nodes), do: "btn-error", else: "btn-outline")
              ]}
            >
              <.icon name="hero-globe-alt" class="w-4 h-4 mr-1" />
              DNS
              <span :if={match?({:error, _}, @expected_data.nodes)} class="ml-1">⚠</span>
            </.button>

            <.button
              phx-click="refresh_active"
              class={[
                "btn btn-sm",
                if(match?({:error, _}, @active_data.members), do: "btn-error", else: "btn-outline")
              ]}
            >
              <.icon name="hero-command-line" class="w-4 h-4 mr-1" />
              CLI
              <span :if={match?({:error, _}, @active_data.members)} class="ml-1">⚠</span>
            </.button>

            <.button phx-click="reset_tracking" class="btn btn-warning btn-outline">
              <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Reset Tracking
            </.button>

            <.button phx-click="send_message" variant="primary">
              <.icon name="hero-paper-airplane" class="w-4 h-4 mr-2" /> Send Message
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

          <!-- Real-time acknowledgment progress -->
          <div class="mb-4">
            <div class="flex items-center justify-between text-sm mb-2">
              <span>Acknowledgment Progress:</span>
              <div class="flex items-center gap-2 text-sm">
                <span class="badge badge-success badge-sm">
                  {length(@ack_regions)} acknowledged
                </span>
                <span class="badge badge-warning badge-sm">
                  {length(@expected_regions)} expected
                </span>
              </div>
            </div>
            <div class="w-full bg-base-300 rounded-full h-2">
              <div
                class="h-2 rounded-full bg-gradient-to-r from-orange-500 to-violet-500 transition-all duration-500"
                style={"width: #{if length(@expected_regions) > 0, do: length(@ack_regions) / length(@expected_regions) * 100, else: 0}%"}
              >
              </div>
            </div>
          </div>

          <!-- Region legend -->
          <div class="text-sm text-base-content/70 space-y-2">
            <div class="flex items-center">
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #77b5fe;"></span>
              Our node
              <%= if @our_regions != [] do %>
                ({@our_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")})
              <% else %>
                (region unknown)
              <% end %>
            </div>

            <div class="flex items-center">
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ffdc66;"></span>
              Active nodes (CLI)
              <%= if @active_regions != [] do %>
                ({@active_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ")})
              <% else %>
                (none found)
              <% end %>
              <%= if match?({:error, _}, @active_data.members) do %>
                <span class="badge badge-error badge-xs ml-2">error</span>
              <% end %>
            </div>

            <div class="flex items-center">
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ff8c42;"></span>
              Nodes from DNS
              <%= dns_regions_display(@expected_regions) %>
              <%= if match?({:error, _}, @expected_data.nodes) do %>
                <span class="badge badge-warning badge-xs ml-2">error</span>
              <% end %>
            </div>

            <div class="flex items-center">
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #9d4edd;"></span>
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

      <!-- Summary Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Expected Nodes</div>
          <div class="stat-value text-2xl flex items-center">
            <%= case @expected_data.nodes do %>
              <% {:ok, nodes} -> %>
                {length(nodes)}
              <% {:error, _} -> %>
                <span class="text-error">?</span>
            <% end %>
          </div>
          <div class="stat-desc">{length(@expected_regions)} regions</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Active Members</div>
          <div class="stat-value text-2xl flex items-center">
            <%= case @active_data.members do %>
              <% {:ok, members} -> %>
                {length(members)}
              <% {:error, _} -> %>
                <span class="text-error">?</span>
            <% end %>
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
      </div>

      <!-- Last Updated -->
      <div class="text-xs text-base-content/70 text-center">
        Page updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end
end

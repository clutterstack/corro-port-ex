defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{ClusterCards, MembersTable, DebugSection, NavTabs}
  alias CorroPort.{CorrosionCLI, DNSNodeDiscovery, AckTracker}

  # 5 minutes refresh interval
  @refresh_interval 300_000

  def mount(_params, _session, socket) do
    # Subscribe to acknowledgment updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CorroPort.PubSub, AckTracker.get_pubsub_topic())
    end

    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000

    socket =
      assign(socket, %{
        page_title: "Cluster Status",
        cluster_info: nil,
        local_info: nil,
        node_messages: [],
        error: nil,
        last_updated: nil,
        corro_api_port: CorroPort.CorrosionClient.get_corro_api_port(),
        phoenix_port: phoenix_port,
        refresh_interval: @refresh_interval,
        # Initialize region data
        active_regions: [],
        our_regions: [],
        expected_regions: [],  # DNS-sourced expected nodes
        ack_regions: [],       # Regions that have acknowledged latest message
        # Initialize ack_status for the template conditions
        ack_status: nil,
        # CLI-related state
        cli_members_task: nil,
        cli_members_data: nil,
        cli_members_loading: false,
        cli_members_error: nil
      })

    {:ok, fetch_cluster_data(socket)}
  end

  # Event handlers

  def handle_event("send_message", _params, socket) do
    case CorroPortWeb.ClusterLive.MessageHandler.send_message() do
      {:ok, success_message, message_data} ->
        Logger.debug("ClusterLive: ✅ Message sent successfully: #{inspect(message_data)}")

        # Track this message for acknowledgment monitoring
        track_message_data = %{
          pk: message_data.pk,
          timestamp: message_data.timestamp,
          node_id: message_data.node_id
        }

        CorroPort.AckTracker.track_latest_message(track_message_data)
        Logger.debug("ClusterLive: Now tracking message #{message_data.pk} for acknowledgments")

        socket =
          socket
          |> assign(:ack_regions, [])  # Reset ack regions since we're tracking a new message
          |> put_flash(:info, success_message)

        {:noreply, socket}

      {:error, error} ->
        socket = put_flash(socket, :error, "Failed to send message: #{error}")
        {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket) do
    Logger.debug("ClusterLive: 🔄 Manual refresh triggered")
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_event("fetch_cli_members", _params, socket) do
    Logger.debug("ClusterLive: 🔧 CLI cluster members fetch triggered")

    # Start the async task
    task = CorrosionCLI.cluster_members_async()

    socket =
      socket
      |> assign(:cli_members_task, task)
      |> assign(:cli_members_loading, true)
      |> assign(:cli_members_error, nil)
      |> put_flash(:info, "Fetching cluster members via CLI...")

    {:noreply, socket}
  end

  def handle_event("clear_cli_data", _params, socket) do
    socket =
      socket
      |> assign(:cli_members_data, nil)
      |> assign(:cli_members_error, nil)
      |> assign(:cli_members_task, nil)
      |> assign(:cli_members_loading, false)

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


  def handle_event("reset_tracking", _params, socket) do
    case CorroPort.AckTracker.reset_tracking() do
      :ok ->
        Logger.info("ClusterLive: ✅ Message tracking reset successfully")
        socket =
          socket
          |> assign(:ack_regions, [])  # Clear the violet regions immediately
          |> put_flash(:info, "Message tracking reset - all nodes are now orange (expected)")
        {:noreply, socket}

      {:error, error} ->
        Logger.warning("ClusterLive: ❌ Failed to reset tracking: #{inspect(error)}")
        socket = put_flash(socket, :error, "Failed to reset tracking: #{inspect(error)}")
        {:noreply, socket}
    end
  end

  # handle CLI task completion
  def handle_info({task_ref, {:ok, raw_output}}, socket) do
    Logger.debug("handling {:ok, #{inspect(raw_output)}} from task #{inspect(task_ref)}")

    # Use the dedicated parser
    parsed_result =
      case CorroPort.CorrosionParser.parse_cluster_members(raw_output) do
        {:ok, []} ->
          Logger.info("ClusterLive: No cluster members found - single node setup")
          %{}

        {:ok, members} ->
          Logger.info("ClusterLive: Parsed some CLI members")
          members

        {:error, reason} ->
          Logger.warning("ClusterLive: Failed to parse CLI output: #{inspect(reason)}")
          %{parse_error: reason, raw_output: raw_output}
      end

    flash_message =
      case parsed_result do
        %{} -> "✅ CLI command successful - single node setup (no cluster members)"
        list when is_list(list) -> "✅ CLI cluster members fetched successfully!"
        %{parse_error: _} -> "⚠️ CLI command succeeded but output couldn't be parsed"
      end

    socket =
      socket
      |> assign(:cli_members_data, parsed_result)
      |> assign(:cli_members_loading, false)
      |> assign(:cli_members_task, nil)
      |> put_flash(:info, flash_message)

    {:noreply, socket}
  end


  # Handle acknowledgment updates
  def handle_info({:ack_update, ack_status}, socket) do
    Logger.debug("ClusterLive: 🤝 Received acknowledgment update")

    ack_regions = extract_ack_regions(ack_status)

    socket = assign(socket, :ack_regions, ack_regions)
    {:noreply, socket}
  end

  # handle task process cleanup
  def handle_info({:DOWN, ref, :process, _pid, :normal}, socket) do
    Logger.info("Handled :DOWN message from #{inspect(ref)}")
    {:noreply, socket}
  end

  # Private functions

 defp fetch_cluster_data(socket) do
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data()

    # Get region data from message activity
    {active_regions, our_regions} = get_cluster_regions(updates)

    # Get expected regions from DNS discovery
    expected_regions = get_expected_regions_from_dns()

    # Get acknowledgment regions and status
    ack_status = CorroPort.AckTracker.get_status()
    ack_regions = extract_ack_regions(ack_status)

    assign(socket, %{
      cluster_info: updates.cluster_info,
      local_info: updates.local_info,
      node_messages: updates.node_messages,
      error: updates.error,
      last_updated: updates.last_updated,
      active_regions: active_regions,
      our_regions: our_regions,
      expected_regions: expected_regions,
      ack_regions: ack_regions,
      ack_status: ack_status
    })
  end

  defp extract_ack_regions_from_current_status do
    case AckTracker.get_status() do
      %{acknowledgments: acks} when is_list(acks) ->
        extract_ack_regions(%{acknowledgments: acks})
      _ ->
        []
    end
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

  defp get_expected_regions_from_dns do
    case DNSNodeDiscovery.get_expected_nodes() do
      {:ok, expected_nodes} ->
        # Extract regions from node IDs like "region-machine_id"
        regions =
          expected_nodes
          |> Enum.map(&CorroPort.CorrosionParser.extract_region_from_node_id/1)
          |> Enum.reject(&(&1 == "unknown"))
          |> Enum.uniq()

        Logger.debug("ClusterLive: Expected regions from DNS: #{inspect(regions)}")
        regions

      {:error, reason} ->
        Logger.debug("ClusterLive: Failed to get expected nodes from DNS: #{inspect(reason)}")
        []
    end
  end

  defp get_cluster_regions(updates) do
    # Get regions from recent message activity
    message_regions = get_regions_from_messages(updates.node_messages)

    # Debug: log what we found
    Logger.debug("ClusterLive: Message regions: #{inspect(message_regions)}")

    # Get our local region
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    our_region = CorroPort.CorrosionParser.extract_region_from_node_id(local_node_id)

    Logger.debug("ClusterLive: Local node_id: #{local_node_id}, extracted region: #{our_region}")

    # Combine all active regions (excluding our own for separate display)
    other_regions = Map.values(message_regions) |> Enum.reject(&(&1 == our_region)) |> Enum.uniq()
    our_regions = if our_region != "unknown", do: [our_region], else: []

    Logger.debug("ClusterLive: Other regions: #{inspect(other_regions)}, Our regions: #{inspect(our_regions)}")

    {other_regions, our_regions}
  end

  defp get_regions_from_messages(messages) when is_list(messages) do
    messages
    |> Enum.map(fn msg ->
      node_id = Map.get(msg, "node_id")
      # First try the region field if it exists
      region = Map.get(msg, "region") || CorroPort.CorrosionParser.extract_region_from_node_id(node_id)
      {node_id, region}
    end)
    |> Enum.reject(fn {_node_id, region} -> region == "unknown" end)
    |> Enum.into(%{})
  end

  defp get_regions_from_messages(_), do: %{}

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:cluster} />

      <ClusterCards.cluster_header_with_actions ack_regions={@ack_regions} />

      <ClusterCards.error_alerts error={@error} />

<!-- Enhanced World Map with Regions -->
      <div class="card bg-base-100">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h3 class="card-title">
              <.icon name="hero-globe-alt" class="w-5 h-5 mr-2" /> Geographic Distribution
            </h3>
            <div class="flex gap-2">
              <.button
                :if={@ack_regions != []}
                phx-click="reset_tracking"
                class="btn btn-xs btn-warning btn-outline">
                <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Reset
              </.button>
              <.button phx-click="refresh_dns_cache" class="btn btn-xs btn-outline">
                <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh DNS
              </.button>
            </div>
          </div>

          <div class="rounded-lg border">
            <CorroPortWeb.WorldMap.world_map_svg
              regions={@active_regions}
              our_regions={@our_regions}
              expected_regions={@expected_regions}
              ack_regions={@ack_regions}
            />
          </div>

          <!-- Real-time acknowledgment progress bar -->
          <div :if={@ack_regions != [] or (@ack_status && @ack_status.latest_message)} class="mb-4">
            <div class="flex items-center justify-between text-sm mb-2">
              <span>Acknowledgment Progress:</span>
              <span>{length(@ack_regions)}/{length(@expected_regions)} regions</span>
            </div>
            <div class="w-full bg-base-300 rounded-full h-2">
              <div
                class="h-2 rounded-full bg-gradient-to-r from-orange-500 to-violet-500 transition-all duration-500"
                style={"width: #{if length(@expected_regions) > 0, do: length(@ack_regions) / length(@expected_regions) * 100, else: 0}%"}
              >
              </div>
            </div>
          </div>

           <!-- Message Tracking Status -->
      <div :if={@ack_regions != [] or (@ack_status && @ack_status.latest_message)} class="card bg-base-200 border-l-4 border-primary">
        <div class="card-body py-3">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <.icon name="hero-radio" class="w-5 h-5 text-primary" />
              <div>
                <div class="font-semibold text-sm">Tracking Message Acknowledgments</div>
                <div class="text-xs text-base-content/70">
                  Watch the map as nodes acknowledge the message
                </div>
              </div>
            </div>
            <div class="flex items-center gap-2 text-sm">
              <span class="badge badge-success badge-sm">
                {length(@ack_regions)} acknowledged
              </span>
              <span class="badge badge-warning badge-sm">
                {length(@expected_regions)} expected
              </span>
            </div>
          </div>
        </div>
      </div>

          <div class="text-sm text-base-content/70 space-y-2">
            <div class="flex items-center">
              <!-- Our node (yellow) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ffdc66;"></span>
              Our node
              <%= if @our_regions != [] do %>
                (<%= @our_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ") %>)
              <% else %>
                (region unknown)
              <% end %>
            </div>

            <div class="flex items-center">
              <!-- Active other nodes (blue) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #77b5fe;"></span>
              Other active nodes
              <%= if @active_regions != [] do %>
                (<%= @active_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ") %>)
              <% else %>
                (none active)
              <% end %>
            </div>

            <div class="flex items-center">
              <!-- Expected nodes from DNS (orange) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ff8c42;"></span>
              Expected nodes (DNS)
              <%= if @expected_regions != [] do %>
                (<%= @expected_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ") %>)
              <% else %>
                (none found)
              <% end %>
            </div>

            <div class="flex items-center">
              <!-- Acknowledged nodes (plasma violet) -->
              <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #9d4edd;"></span>
              Acknowledged latest message
              <%= if @ack_regions != [] do %>
                (<%= @ack_regions |> Enum.reject(&(&1 == "" or &1 == "unknown")) |> Enum.join(", ") %>)
              <% else %>
                (none yet)
              <% end %>
            </div>

            <!-- Instructions when no message is being tracked -->
            <div :if={@ack_regions == [] and (!@ack_status or !@ack_status.latest_message)} class="mt-3 p-3 bg-base-200 rounded-lg">
              <div class="flex items-center gap-2 text-info">
                <.icon name="hero-information-circle" class="w-4 h-4" />
                <span class="font-semibold">Ready to track acknowledgments</span>
              </div>
              <div class="text-xs mt-1">
                Click "Send Message" to broadcast a message and watch regions turn violet as they acknowledge
              </div>
            </div>
          </div>
        </div>
      </div>

      <ClusterCards.status_cards_simple
        local_info={@local_info}
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
          <h3 class="card-title">
            <.icon name="hero-command-line" class="w-5 h-5 mr-2" /> CLI Cluster Members
          </h3>

          <div class="flex items-center gap-3 mb-4">
            <.button
              phx-click="fetch_cli_members"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-command-line" class="w-4 h-4 mr-2" />
              {if @cli_members_loading, do: "Fetching...", else: "Fetch CLI Members"}
            </.button>

            <.button
              :if={@cli_members_data || @cli_members_error}
              phx-click="clear_cli_data"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-x-mark" class="w-4 h-4 mr-2" /> Clear
            </.button>

            <div :if={@cli_members_loading} class="flex items-center">
              <div class="loading loading-spinner loading-sm mr-2"></div>
              <span class="text-sm text-base-content/70">Running CLI command...</span>
            </div>
          </div>

          <!-- CLI Results -->
          <div :if={@cli_members_data && is_list(@cli_members_data)} class="space-y-4">
            <div :if={@cli_members_data == []} class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>No cluster members found - this appears to be a single node setup</span>
            </div>

            <div :if={@cli_members_data != []} class="alert alert-success">
              <.icon name="hero-check-circle" class="w-5 h-5" />
              <span>Found {length(@cli_members_data)} cluster members via CLI</span>
            </div>

            <div :if={@cli_members_data != []} class="overflow-x-auto">
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
                  <tr :for={member <- @cli_members_data}>
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

          <!-- Parse Error Display -->
          <div
            :if={
              @cli_members_data && is_map(@cli_members_data) &&
                Map.has_key?(@cli_members_data, :parse_error)
            }
            class="space-y-4"
          >
            <div class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>CLI command succeeded but failed to parse output</span>
            </div>

            <details class="collapse collapse-arrow bg-base-200">
              <summary class="collapse-title">Raw CLI Output</summary>
              <div class="collapse-content">
                <pre class="bg-base-300 p-4 rounded text-xs overflow-auto">{@cli_members_data.raw_output}</pre>
              </div>
            </details>

            <details class="collapse collapse-arrow bg-base-200">
              <summary class="collapse-title">Parse Error Details</summary>
              <div class="collapse-content">
                <pre class="bg-base-300 p-4 rounded text-xs overflow-auto">{inspect(@cli_members_data.parse_error, pretty: true)}</pre>
              </div>
            </details>
          </div>

          <!-- Error Display -->
          <div :if={@cli_members_error} class="alert alert-error">
            <.icon name="hero-exclamation-circle" class="w-5 h-5" />
            <div>
              <div class="font-semibold">CLI Command Failed</div>
              <div class="text-sm">{@cli_members_error}</div>
            </div>
          </div>

          <!-- Help Text -->
          <div
            :if={!@cli_members_data && !@cli_members_error && !@cli_members_loading}
            class="text-center py-4"
          >
            <.icon name="hero-command-line" class="w-8 h-8 mx-auto text-base-content/30 mb-2" />
            <div class="text-sm text-base-content/70">
              Click "Fetch CLI Members" to run
              <code class="bg-base-300 px-1 rounded">corrosion cluster members</code>
            </div>
            <div class="text-xs text-base-content/50 mt-1">
              This uses the CLI directly instead of the HTTP API
            </div>
          </div>
        </div>
      </div>

      <MembersTable.cluster_members_table cluster_info={@cluster_info} />

      <DebugSection.debug_section
        cluster_info={@cluster_info}
        local_info={@local_info}
        node_messages={@node_messages}
      />
    </div>
    """
  end
end

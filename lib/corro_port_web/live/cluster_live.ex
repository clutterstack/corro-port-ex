defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.CorrosionAPI

  @refresh_interval 3000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
    end

    # Detect the correct API port
    detected_port = CorrosionAPI.detect_api_port()
    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000

    socket =
      socket
      |> assign(:page_title, "Cluster Status")
      |> assign(:cluster_info, nil)
      |> assign(:local_info, nil)
      |> assign(:node_messages, [])
      |> assign(:error, nil)
      |> assign(:last_updated, nil)
      |> assign(:api_port, detected_port)
      |> assign(:phoenix_port, phoenix_port)
      |> assign(:refresh_interval, @refresh_interval)
      |> assign(:sending_message, false)

    {:ok, fetch_cluster_data(socket)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_event("send_message", _params, socket) do
    api_port = socket.assigns.api_port

    # Create a message with timestamp
    message = "Hello from #{CorroPort.NodeConfig.get_corrosion_node_id()} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    socket = assign(socket, :sending_message, true)

    case CorroPort.CorrosionAPI.insert_message(message, api_port) do
      {:ok, result} ->
        Logger.info("Successfully sent message: #{inspect(result)}")
        socket
        |> assign(:sending_message, false)
        |> put_flash(:info, "Message sent successfully!")
        |> fetch_cluster_data()

      {:error, error} ->
        Logger.warning("Failed to send message: #{error}")
        socket
        |> assign(:sending_message, false)
        |> put_flash(:error, "Failed to send message: #{error}")
    end
    |> then(&{:noreply, &1})
  end

  defp fetch_cluster_data(socket) do
    api_port = socket.assigns.api_port

    # Fetch cluster info
    socket = case CorrosionAPI.get_cluster_info(api_port) do
      {:ok, cluster_info} ->
        assign(socket, :cluster_info, cluster_info)
      {:error, error} ->
        Logger.warning("Failed to fetch cluster info: #{error}")
        assign(socket, :error, "Failed to connect to Corrosion API: #{error}")
    end

    # Fetch local info
    socket = case CorrosionAPI.get_info(api_port) do
      {:ok, local_info} ->
        assign(socket, :local_info, local_info)
      {:error, error} ->
        Logger.warning("Failed to fetch local info: #{error}")
        socket
    end

    # Fetch node messages
    socket = case CorrosionAPI.get_latest_node_messages(api_port) do
      {:ok, messages} ->
        assign(socket, :node_messages, messages)
      {:error, error} ->
        Logger.debug("Failed to fetch node messages (table might not exist yet): #{error}")
        assign(socket, :node_messages, [])
    end

    assign(socket, :last_updated, DateTime.utc_now())
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp format_timestamp(nil), do: "Unknown"
  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> timestamp
    end
  end
  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_timestamp(_), do: "Unknown"

  defp get_gossip_address do
    config = Application.get_env(:corro_port, :node_config, %{
      corrosion_gossip_port: 8787
    })
    gossip_port = config[:corrosion_gossip_port] || 8787
    "127.0.0.1:#{gossip_port}"
  end

  defp get_local_node_id(local_info) when is_map(local_info) do
    Map.get(local_info, "node_id", "unknown")
  end
  defp get_local_node_id(_), do: "unknown"

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Corrosion Cluster Status
        <:subtitle>
          Monitoring cluster health and node connectivity
        </:subtitle>
        <:actions>
          <.button phx-click="refresh" variant="primary">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" />
            Refresh
          </.button>
          <.button
            phx-click="send_message"
            disabled={@sending_message}
            class="btn btn-secondary"
          >
            <span :if={@sending_message} class="loading loading-spinner loading-sm mr-2"></span>
            <.icon :if={!@sending_message} name="hero-paper-airplane" class="w-4 h-4 mr-2" />
            Send Message
          </.button>
        </:actions>
      </.header>

      <div class="alert alert-info" :if={@error}>
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <span><%= @error %></span>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <!-- Local Node Info -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-sm">Local Node</h3>
            <div :if={@local_info} class="space-y-2 text-sm">
              <div><strong>Node ID:</strong> <%= Map.get(@local_info, "node_id", "Unknown") %></div>
              <div><strong>Phoenix Port:</strong> <%= @phoenix_port %></div>
              <div><strong>API Port:</strong> <%= @api_port %></div>
              <div><strong>Gossip Address:</strong> <%= get_gossip_address() %></div>
              <div><strong>User Tables:</strong>
                <%= case Map.get(@local_info, "tables") do
                  tables when is_list(tables) -> length(tables)
                  _ -> 0
                end %>
              </div>
              <div><strong>Status:</strong>
                <span class="badge badge-success badge-sm">Active</span>
              </div>
            </div>
            <div :if={!@local_info && !@error} class="loading loading-spinner loading-sm"></div>
          </div>
        </div>

        <!-- Cluster Summary -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-sm">Cluster Summary</h3>
            <div :if={@cluster_info} class="space-y-2 text-sm">
              <div><strong>Total Nodes:</strong> <%= Map.get(@cluster_info, "member_count", 0) + 1 %></div>
              <div><strong>Remote Members:</strong> <%= Map.get(@cluster_info, "member_count", 0) %></div>
              <div><strong>Tracked Peers:</strong> <%= Map.get(@cluster_info, "peer_count", 0) %></div>
              <div><strong>Messages Sent:</strong> <%= length(@node_messages) %> nodes</div>
              <div><strong>Last Updated:</strong> <%= format_timestamp(@last_updated) %></div>
            </div>
            <div :if={!@cluster_info && !@error} class="loading loading-spinner loading-sm"></div>
          </div>
        </div>

        <!-- Auto Refresh Info -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-sm">Monitoring</h3>
            <div class="space-y-2 text-sm">
              <div><strong>Auto Refresh:</strong> Every <%= div(@refresh_interval, 1000) %>s</div>
              <div><strong>Last Check:</strong>
                <span :if={@last_updated}>
                  <%= format_timestamp(@last_updated) %>
                </span>
                <span :if={!@last_updated}>Never</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Node Messages -->
      <div :if={@node_messages != []} class="card bg-base-100">
        <div class="card-body">
          <h3 class="card-title">Latest Messages from Each Node</h3>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>Node ID</th>
                  <th>Message</th>
                  <th>Timestamp</th>
                  <th>Sequence</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={message <- @node_messages}>
                  <td class="font-mono text-sm">
                    <%= Map.get(message, "node_id", "Unknown") %>
                  </td>
                  <td class="max-w-md truncate">
                    <%= Map.get(message, "message", "") %>
                  </td>
                  <td class="text-xs">
                    <%= format_timestamp(Map.get(message, "timestamp")) %>
                  </td>
                  <td class="font-mono text-xs">
                    <%= Map.get(message, "sequence", "") %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- Cluster Members Table -->
      <div :if={@cluster_info} class="card bg-base-100">
        <div class="card-body">
          <h3 class="card-title">Cluster Members</h3>

          <div :if={Map.get(@cluster_info, "members", []) != []} class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>Node ID</th>
                  <th>Address</th>
                  <th>State</th>
                  <th>Incarnation</th>
                  <th>Timestamp</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={member <- Map.get(@cluster_info, "members", [])}>
                  <td :if={Map.has_key?(member, "parse_error")} colspan="5" class="text-error">
                    Parse Error: <%= Map.get(member, "parse_error") %>
                    <details class="mt-1">
                      <summary class="text-xs cursor-pointer">Raw data</summary>
                      <pre class="text-xs mt-1"><%= inspect(member, pretty: true) %></pre>
                    </details>
                  </td>
                  <td :if={!Map.has_key?(member, "parse_error")} class="font-mono text-xs">
                    <%= case Map.get(member, "member_id") do
                      nil -> "Unknown"
                      id -> String.slice(id, 0, 8) <> "..."
                    end %>
                  </td>
                  <td :if={!Map.has_key?(member, "parse_error")} class="font-mono text-sm">
                    <%= Map.get(member, "member_addr", "Unknown") %>
                  </td>
                  <td :if={!Map.has_key?(member, "parse_error")}>
                    <span class={[
                      "badge badge-sm",
                      case Map.get(member, "member_state") do
                        "Alive" -> "badge-success"
                        "Suspect" -> "badge-warning"
                        "Down" -> "badge-error"
                        _ -> "badge-neutral"
                      end
                    ]}>
                      <%= Map.get(member, "member_state", "Unknown") %>
                    </span>
                  </td>
                  <td :if={!Map.has_key?(member, "parse_error")}><%= Map.get(member, "member_incarnation", "?") %></td>
                  <td :if={!Map.has_key?(member, "parse_error")} class="text-xs">
                    <%= CorroPort.CorrosionAPI.format_corrosion_timestamp(Map.get(member, "member_ts")) %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={Map.get(@cluster_info, "tracked_peers", []) != []} class="mt-6">
            <h4 class="font-semibold mb-2">Tracked Peers</h4>
            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>Peer Info</th>
                    <th>Details</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={peer <- Map.get(@cluster_info, "tracked_peers", [])}>
                    <td class="font-mono text-sm">
                      <%= inspect(peer) |> String.slice(0, 50) %>...
                    </td>
                    <td><%= inspect(peer) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div :if={Map.get(@cluster_info, "members", []) == [] && Map.get(@cluster_info, "tracked_peers", []) == []}>
            <p class="text-base-content/70">No cluster members or peers found. This might be a single-node setup or the cluster is still forming.</p>
          </div>
        </div>
      </div>

      <!-- Raw Data (for debugging) -->
      <details class="collapse collapse-arrow bg-base-200" :if={@cluster_info || @local_info}>
        <summary class="collapse-title text-sm font-medium">Raw API Response (Debug)</summary>
        <div class="collapse-content">
          <div :if={@cluster_info} class="mb-4">
            <h4 class="font-semibold mb-2">Cluster Info:</h4>
            <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@cluster_info, pretty: true) %></pre>
          </div>
          <div :if={@local_info} class="mb-4">
            <h4 class="font-semibold mb-2">Local Info:</h4>
            <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@local_info, pretty: true) %></pre>
          </div>
          <div :if={@node_messages != []} class="mb-4">
            <h4 class="font-semibold mb-2">Node Messages:</h4>
            <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@node_messages, pretty: true) %></pre>
          </div>
        </div>
      </details>
    </div>
    """
  end
end

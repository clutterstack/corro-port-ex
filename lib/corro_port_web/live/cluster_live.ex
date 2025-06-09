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
      |> assign(:error, nil)
      |> assign(:last_updated, nil)
      |> assign(:api_port, detected_port)
      |> assign(:phoenix_port, phoenix_port)
      |> assign(:refresh_interval, @refresh_interval)

    {:ok, fetch_cluster_data(socket)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_cluster_data(socket)}
  end

  defp fetch_cluster_data(socket) do
    api_port = socket.assigns.api_port

    case CorrosionAPI.get_cluster_info(api_port) do
      {:ok, cluster_info} ->
        case CorrosionAPI.get_info(api_port) do
          {:ok, local_info} ->
            socket
            |> assign(:cluster_info, cluster_info)
            |> assign(:local_info, local_info)
            |> assign(:error, nil)
            |> assign(:last_updated, DateTime.utc_now())

          {:error, error} ->
            Logger.warning("Failed to fetch local info: #{error}")
            socket
            |> assign(:cluster_info, cluster_info)
            |> assign(:local_info, nil)
            |> assign(:error, "Failed to fetch local info: #{error}")
            |> assign(:last_updated, DateTime.utc_now())
        end

      {:error, error} ->
        Logger.warning("Failed to fetch cluster info: #{error}")
        socket
        |> assign(:cluster_info, nil)
        |> assign(:local_info, nil)
        |> assign(:error, "Failed to connect to Corrosion API: #{error}")
        |> assign(:last_updated, DateTime.utc_now())
    end
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

  defp connection_status(true), do: {"Connected", "badge-success"}
  defp connection_status(false), do: {"Disconnected", "badge-error"}
  defp connection_status(_), do: {"Unknown", "badge-warning"}

  defp parse_member_state(member) do
    case Map.get(member, "foca_state") do
      nil -> "Unknown"
      foca_state_json ->
        case Jason.decode(foca_state_json) do
          {:ok, %{"state" => state}} -> state
          _ -> "Unknown"
        end
    end
  end

  defp parse_member_node_id(member) do
    case Map.get(member, "foca_state") do
      nil -> "Unknown"
      foca_state_json ->
        case Jason.decode(foca_state_json) do
          {:ok, %{"id" => %{"id" => node_id}}} ->
            String.slice(node_id, 0, 8) <> "..."
          _ -> "Unknown"
        end
    end
  end

  defp member_state_badge_class(state) do
    case state do
      "Alive" -> "badge badge-success badge-sm"
      "Suspect" -> "badge badge-warning badge-sm"
      "Down" -> "badge badge-error badge-sm"
      _ -> "badge badge-neutral badge-sm"
    end
  end

  defp count_members_by_state(cluster_info, target_states) when is_list(target_states) do
    members = Map.get(cluster_info, "members", [])

    Enum.count(members, fn member ->
      state = parse_member_state(member)
      state in target_states
    end)
  end

  defp count_members_by_state(cluster_info, target_state) do
    count_members_by_state(cluster_info, [target_state])
  end

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
              <div><strong>Total Members:</strong> <%= Map.get(@cluster_info, "member_count", 0) %></div>
              <div><strong>Active Members:</strong>
                <span class="badge badge-success badge-sm">
                  <%= count_members_by_state(@cluster_info, "Alive") %>
                </span>
              </div>
              <div><strong>Suspect/Down:</strong>
                <span class="badge badge-warning badge-sm">
                  <%= count_members_by_state(@cluster_info, ["Suspect", "Down"]) %>
                </span>
              </div>
              <div><strong>Tracked Peers:</strong> <%= Map.get(@cluster_info, "peer_count", 0) %></div>
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

      <!-- Cluster Members Table -->
      <div :if={@cluster_info} class="card bg-base-100">
        <div class="card-body">
          <h3 class="card-title">Cluster Members</h3>

          <div :if={Map.get(@cluster_info, "members", []) != []} class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>Address</th>
                  <th>State</th>
                  <th>Node ID</th>
                  <th>Last Updated</th>
                  <th>RTT</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={member <- Map.get(@cluster_info, "members", [])}>
                  <td class="font-mono text-sm"><%= Map.get(member, "address", "Unknown") %></td>
                  <td>
                    <span class={member_state_badge_class(parse_member_state(member))}>
                      <%= parse_member_state(member) %>
                    </span>
                  </td>
                  <td class="font-mono text-xs"><%= parse_member_node_id(member) %></td>
                  <td class="text-sm"><%= format_timestamp(Map.get(member, "updated_at")) %></td>
                  <td class="text-sm">
                    <%= case Map.get(member, "rtt_min") do
                      nil -> "N/A"
                      rtt -> "#{rtt}ms"
                    end %>
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
          <div :if={@local_info}>
            <h4 class="font-semibold mb-2">Local Info:</h4>
            <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@local_info, pretty: true) %></pre>
          </div>
        </div>
      </details>
    </div>
    """
  end
end

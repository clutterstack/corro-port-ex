defmodule CorroPortWeb.ClusterCards do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @moduledoc """
  Function components to illustrate Corrosion cluster status.

  """

def cluster_header(assigns) do
  ~H"""
  <.header>
    Corrosion Cluster Status
    <:subtitle>
      <div class="flex items-center gap-4">
        <span>Monitoring cluster health and node connectivity</span>
      </div>
    </:subtitle>
    <:actions>
      <.button phx-click="refresh" variant="primary">
        <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" />
        Refresh
      </.button>
      <.button
        phx-click="send_message"
        class="btn btn-secondary"
      >
        <.icon name="hero-paper-airplane" class="w-4 h-4 mr-2" />
        Send Message
      </.button>
    </:actions>
  </.header>
  """
end
  def error_alerts(assigns) do
    ~H"""
    <div>
      <%= if assigns[:error] do %>
      <div class="alert alert-info">
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <span><%= assigns[:error] %></span>
      </div>
      <% end %>
    </div>
    """
  end

def status_cards(assigns) do
  ~H"""
  <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
    <.local_node_card
      local_info={@local_info}
      cluster_info={@cluster_info}
      phoenix_port={@phoenix_port}
      api_port={@api_port}
      error={@error}
    />

    <.cluster_summary_card
      cluster_info={@cluster_info}
      node_messages={@node_messages}
      last_updated={@last_updated}
      error={@error}
    />

    <.message_activity_card
      node_messages={@node_messages}
      last_updated={@last_updated}
      refresh_interval={@refresh_interval}
    />

     <.replication_status_card
        replication_status={@replication_status}
      />

  </div>
  """
end
def message_activity_card(assigns) do
  # Calculate if we have recent activity
  recent_activity = if assigns.node_messages != [] do
    # Check if any message is from the last 5 minutes
    five_minutes_ago = DateTime.add(DateTime.utc_now(), -5, :minute)

    Enum.any?(assigns.node_messages, fn msg ->
      case Map.get(msg, "timestamp") do
        timestamp when is_binary(timestamp) ->
          case DateTime.from_iso8601(timestamp) do
            {:ok, dt, _} -> DateTime.after?(dt, five_minutes_ago)
            _ -> false
          end
        _ -> false
      end
    end)
  else
    false
  end

  assigns = assign(assigns, :recent_activity, recent_activity)

  ~H"""
  <div class="card bg-base-200">
    <div class="card-body">
      <h3 class="card-title text-sm flex items-center">
        Message Activity
        <span :if={@recent_activity} class="badge badge-success badge-sm ml-2">
          <.icon name="hero-signal" class="w-3 h-3 mr-1" />
          Live
        </span>
        <span :if={!@recent_activity} class="badge badge-warning badge-sm ml-2">
          Quiet
        </span>
      </h3>
      <div class="space-y-2 text-sm">
        <div><strong>Active Nodes:</strong> <%= length(@node_messages) %></div>
        <div><strong>Auto Refresh:</strong> Every <%= div(@refresh_interval, 1000) %>s</div>
        <div><strong>Real-time Updates:</strong>
          <span :if={@recent_activity} class="text-success">Active</span>
          <span :if={!@recent_activity} class="text-warning">No recent activity</span>
        </div>
        <div><strong>Last Check:</strong>
          <span :if={@last_updated}>
            <%= format_timestamp(@last_updated) %>
          </span>
          <span :if={!@last_updated}>Never</span>
        </div>
      </div>
    </div>
  </div>
  """
end


  # Helper function to find the cluster member that matches this local node
  defp find_matching_member(cluster_info, local_info) when is_map(cluster_info) and is_map(local_info) do
    members = Map.get(cluster_info, "members", [])
    local_gossip_port = get_local_gossip_port()

    # Find member whose gossip address matches our local gossip port
    Enum.find(members, fn member ->
      case Map.get(member, "member_addr") do
        addr when is_binary(addr) ->
          # Extract port from address like "127.0.0.1:8787"
          case String.split(addr, ":") do
            [_ip, port_str] ->
              case Integer.parse(port_str) do
                {port, _} -> port == local_gossip_port
                _ -> false
              end
            _ -> false
          end
        _ -> false
      end
    end)
  end
  defp find_matching_member(_, _), do: nil

  defp get_local_gossip_port do
    config = Application.get_env(:corro_port, :node_config, %{
      corrosion_gossip_port: 8787
    })
    config[:corrosion_gossip_port] || 8787
  end

  defp format_member_id(nil), do: "Unknown"
  defp format_member_id(member_id) when byte_size(member_id) > 12 do
    String.slice(member_id, 0, 8) <> "..."
  end
  defp format_member_id(member_id), do: member_id

  def cluster_summary_card(assigns) do
  ~H"""
  <div class="card bg-base-200">
    <div class="card-body">
      <h3 class="card-title text-sm">Cluster Summary</h3>
      <div :if={@cluster_info} class="space-y-2 text-sm">
        <div class="flex items-center justify-between">
          <strong>Active Nodes:</strong>
          <div class="flex items-center gap-2">
            <span class="font-semibold text-lg"><%= Map.get(@cluster_info, "total_active_nodes", 0) %></span>
            <span :if={Map.get(@cluster_info, "local_node_active", false)} class="badge badge-success badge-xs">
              Local Up
            </span>
            <span :if={!Map.get(@cluster_info, "local_node_active", false)} class="badge badge-error badge-xs">
              Local Down
            </span>
          </div>
        </div>

        <div class="flex items-center justify-between">
          <strong>Remote Members:</strong>
          <span><%= Map.get(@cluster_info, "active_member_count", 0) %>/<%= Map.get(@cluster_info, "member_count", 0) %> active</span>
        </div>

        <div><strong>Tracked Peers:</strong> <%= Map.get(@cluster_info, "peer_count", 0) %></div>
        <div><strong>Nodes with Messages:</strong> <%= length(@node_messages) %></div>

        <div class="divider my-1"></div>

        <div class="text-xs text-base-content/70">
          <strong>Last Updated:</strong> <%= format_timestamp(@last_updated) %>
        </div>
      </div>
      <div :if={!@cluster_info && !assigns[:error]} class="loading loading-spinner loading-sm"></div>
    </div>
  </div>
  """
end

def local_node_card(assigns) do
  ~H"""
  <div class="card bg-base-200">
    <div class="card-body">
      <h3 class="card-title text-sm">Local Node</h3>
      <div :if={@local_info} class="space-y-2 text-sm">
        <div><strong>Node ID:</strong>
          <span class="font-mono text-sm">
            <%= Map.get(@local_info, "node_id", "Unknown") %>
          </span>
        </div>
        <div><strong>Phoenix Port:</strong> <%= @phoenix_port %></div>
        <div><strong>API Port:</strong> <%= @api_port %></div>
        <div><strong>Gossip Address:</strong> <%= get_gossip_address() %></div>

        <div class="flex items-center justify-between">
          <strong>Corrosion Status:</strong>
          <span :if={Map.get(@local_info, "local_active", false)} class="badge badge-success badge-sm">
            Responding
          </span>
          <span :if={!Map.get(@local_info, "local_active", false)} class="badge badge-error badge-sm">
            Not Responding
          </span>
        </div>

        <%= if cluster_member = find_matching_member(@cluster_info, @local_info) do %>
          <div class="divider my-1"></div>
          <div><strong>Member ID:</strong>
            <span class="font-mono text-xs">
              <%= format_member_id(cluster_member["member_id"]) %>
            </span>
          </div>
          <div class="flex items-center justify-between">
            <strong>Cluster State:</strong>
            <span class={member_state_badge_class(cluster_member["member_state"])}>
              <%= cluster_member["member_state"] %>
            </span>
          </div>
        <% else %>
          <div class="text-xs text-base-content/70">
            Not found in cluster members (may be seed node)
          </div>
        <% end %>
      </div>
      <div :if={!@local_info && !@error} class="loading loading-spinner loading-sm"></div>
    </div>
  </div>
  """
end

defp member_state_badge_class(state) do
    base_classes = "badge badge-sm"

    state_class = case state do
      "Alive" -> "badge-success"
      "Suspect" -> "badge-warning"
      "Down" -> "badge-error"
      _ -> "badge-neutral"
    end

    "#{base_classes} #{state_class}"
  end

def replication_status_card(assigns) do
  ~H"""
  <div class="card bg-base-200">
    <div class="card-body">
      <h3 class="card-title text-sm flex items-center">
        Replication Status
        <.button
          phx-click="check_replication"
          class="btn btn-xs btn-outline ml-2"
        >
          Check
        </.button>
      </h3>
      <div class="space-y-2 text-sm">
        <div :if={@replication_status}>
          <div><strong>Last Check:</strong> <%= format_timestamp(@replication_status.last_check) %></div>
          <div><strong>Message Count:</strong> <%= @replication_status.total_messages || "Unknown" %></div>
          <div><strong>Sequence Gaps:</strong>
            <span class={if @replication_status.has_gaps, do: "text-warning", else: "text-success"}>
              <%= if @replication_status.has_gaps, do: "⚠️ Found gaps", else: "✅ None" %>
            </span>
          </div>
          <div><strong>Conflicts:</strong>
            <span class={if @replication_status.conflicts > 0, do: "text-error", else: "text-success"}>
              <%= @replication_status.conflicts || 0 %>
            </span>
          </div>
        </div>
        <div :if={!@replication_status} class="text-base-content/70">
          Click "Check" to analyze replication state
        </div>
      </div>
    </div>
  </div>
  """
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




end

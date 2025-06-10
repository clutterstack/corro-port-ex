defmodule CorroPortWeb.ClusterLive.Components do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  def cluster_header(assigns) do
    ~H"""
    <.header>
      Corrosion Cluster Status
      <:subtitle>
        Monitoring cluster health and node connectivity
        <span :if={@subscription_status && @subscription_status.subscription_active} class="badge badge-success badge-sm ml-2">
          Live Updates
        </span>
        <span :if={@subscription_status && !@subscription_status.subscription_active} class="badge badge-warning badge-sm ml-2">
          <%= subscription_status_text(@subscription_status.status) %>
        </span>
      </:subtitle>
      <:actions>
        <.button phx-click="refresh" variant="primary">
          <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" />
          Refresh
        </.button>
        <.button phx-click="check_subscription" class="btn btn-outline">
          <.icon name="hero-signal" class="w-4 h-4 mr-2" />
          Check Sub
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
        <.button phx-click="cleanup_messages" class="btn btn-warning btn-sm">
          <.icon name="hero-trash" class="w-4 h-4 mr-2" />
          Cleanup Bad Data
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

      <%= if assigns[:subscription_status] && Map.get(assigns[:subscription_status], :status) == :error do %>
      <div class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span>Subscription Issue: <%= inspect Map.get(assigns[:subscription_status], :status) %></span>
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

      <.subscription_status_card
        subscription_status={@subscription_status}
        refresh_interval={@refresh_interval}
        last_updated={@last_updated}
      />
    </div>
    """
  end

  def local_node_card(assigns) do
    ~H"""
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
    """
  end

  def cluster_summary_card(assigns) do
    ~H"""
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
        <div :if={!@cluster_info && !assigns[:error]} class="loading loading-spinner loading-sm"></div>
      </div>
    </div>
    """
  end

  def subscription_status_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-sm">Real-time Updates</h3>
        <div class="space-y-2 text-sm">
          <div><strong>Auto Refresh:</strong> Every <%= div(@refresh_interval, 1000) %>s</div>
          <div><strong>Subscription:</strong>
            <span :if={@subscription_status && @subscription_status.subscription_active} class="badge badge-success badge-sm">
              Active
            </span>
            <span :if={@subscription_status && !@subscription_status.subscription_active} class="badge badge-warning badge-sm">
              <%= subscription_status_text(@subscription_status.status) %>
            </span>
            <span :if={!@subscription_status} class="badge badge-neutral badge-sm">
              Unknown
            </span>
          </div>
          <div :if={@subscription_status && @subscription_status.watch_id}>
            <strong>Watch ID:</strong>
            <span class="font-mono text-xs"><%= String.slice(@subscription_status.watch_id, 0, 8) %>...</span>
          </div>
          <div :if={@subscription_status && @subscription_status.reconnect_attempts > 0}>
            <strong>Reconnects:</strong> <%= @subscription_status.reconnect_attempts %>
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

  def node_messages_table(assigns) do
    ~H"""
    <div :if={@node_messages != []} class="card bg-base-100">
      <div class="card-body">
        <h3 class="card-title">
          Latest Messages from Each Node
          <span :if={@subscription_status && @subscription_status.subscription_active} class="badge badge-success badge-sm">
            Live
          </span>
        </h3>
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
    """
  end

  def cluster_members_table(assigns) do
    ~H"""
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
                <.cluster_member_row member={member} />
              </tr>
            </tbody>
          </table>
        </div>

        <.tracked_peers_section cluster_info={@cluster_info} />

        <div :if={Map.get(@cluster_info, "members", []) == [] && Map.get(@cluster_info, "tracked_peers", []) == []}>
          <p class="text-base-content/70">No cluster members or peers found. This might be a single-node setup or the cluster is still forming.</p>
        </div>
      </div>
    </div>
    """
  end

  def cluster_member_row(assigns) do
    ~H"""
    <%= if Map.has_key?(@member, "parse_error") do %>
      <td colspan="5" class="text-error">
        Parse Error: <%= Map.get(@member, "parse_error") %>
        <details class="mt-1">
          <summary class="text-xs cursor-pointer">Raw data</summary>
          <pre class="text-xs mt-1"><%= inspect(@member, pretty: true) %></pre>
        </details>
      </td>
    <% else %>
      <td class="font-mono text-xs">
        <%= case Map.get(@member, "member_id") do
          nil -> "Unknown"
          id -> String.slice(id, 0, 8) <> "..."
        end %>
      </td>
      <td class="font-mono text-sm">
        <%= Map.get(@member, "member_addr", "Unknown") %>
      </td>
      <td>
        <span class={member_state_badge_class(Map.get(@member, "member_state"))}>
          <%= Map.get(@member, "member_state", "Unknown") %>
        </span>
      </td>
      <td><%= Map.get(@member, "member_incarnation", "?") %></td>
      <td class="text-xs">
        <%= CorroPort.ClusterAPI.format_corrosion_timestamp(Map.get(@member, "member_ts")) %>
      </td>
    <% end %>
    """
  end

  def tracked_peers_section(assigns) do
    ~H"""
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
    """
  end

  def debug_section(assigns) do
    ~H"""
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
        <div :if={@subscription_status} class="mb-4">
          <h4 class="font-semibold mb-2">Subscription Status:</h4>
          <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@subscription_status, pretty: true) %></pre>
        </div>
      </div>
    </details>
    """
  end

  # Helper functions
  defp subscription_status_text(status) do
    case status do
      :timeout -> "Timeout"
      :not_started -> "Not Started"
      :error -> "Error"
      :connecting -> "Connecting"
      :reconnecting -> "Reconnecting"
      :failed -> "Failed"
      _ -> "Inactive"
    end
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

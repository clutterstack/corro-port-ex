defmodule CorroPortWeb.ClusterCards do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @moduledoc """
  Function components to illustrate Corrosion cluster status.
  Simplified version focused on cluster monitoring only.
  """

  def cluster_header_simple(assigns) do
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
          <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Refresh
        </.button>
      </:actions>
    </.header>
    """
  end

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
        <.button phx-click="refresh_dns_cache" class="btn btn-xs btn-outline">
          <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh DNS
        </.button>
      </:actions>
    </.header>
    """
  end

  def index_header(assigns) do
    ~H"""
    <.header>
      <.icon name="hero-globe-alt" class="w-5 h-5 mr-2" /> Geographic Distribution
      <:subtitle>
        <div class="flex items-center gap-4">
          <span>Watch changes propagate across the map</span>
        </div>
      </:subtitle>
      <:actions>
        <.button phx-click="refresh_dns_cache" class="btn btn-xs btn-outline">
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
    """
  end

  def error_alerts(assigns) do
    ~H"""
    <div>
      <%= if assigns[:error] do %>
        <div class="alert alert-info">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{assigns[:error]}</span>
        </div>
      <% end %>
    </div>
    """
  end

  def cluster_summary_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-sm">Cluster Summary</h3>
        <div :if={@cluster_info} class="space-y-2 text-sm">
          <div class="flex items-center justify-between">
            <strong>Active Nodes:</strong>
            <div class="flex items-center gap-2">
              <span class="font-semibold text-lg">
                {Map.get(@cluster_info, "total_active_nodes", 0)}
              </span>
              <span
                :if={Map.get(@cluster_info, "local_node_active", false)}
                class="badge badge-success badge-xs"
              >
                Local Up
              </span>
              <span
                :if={!Map.get(@cluster_info, "local_node_active", false)}
                class="badge badge-error badge-xs"
              >
                Local Down
              </span>
            </div>
          </div>

          <div class="flex items-center justify-between">
            <strong>Remote Members:</strong>
            <span>
              {Map.get(@cluster_info, "active_member_count", 0)}/{Map.get(
                @cluster_info,
                "member_count",
                0
              )} active
            </span>
          </div>

          <div><strong>Tracked Peers:</strong> {Map.get(@cluster_info, "peer_count", 0)}</div>

          <div class="divider my-1"></div>

          <div class="text-xs text-base-content/70">
            <strong>Last Updated:</strong> {format_timestamp(@last_updated)}
          </div>
        </div>
        <div :if={!@cluster_info && !assigns[:error]} class="loading loading-spinner loading-sm">
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
    config =
      Application.get_env(:corro_port, :node_config, %{
        corrosion_gossip_port: 8787
      })

    gossip_port = config[:corrosion_gossip_port] || 8787
    "127.0.0.1:#{gossip_port}"
  end
end

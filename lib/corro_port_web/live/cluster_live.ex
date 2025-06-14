defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{ClusterCards, MembersTable, DebugSection, NavTabs}

  # 5 minutes refresh interval
  @refresh_interval 300_000

  def mount(_params, _session, socket) do
    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000

    socket =
      assign(socket, %{
        page_title: "Cluster Status",
        cluster_info: nil,
        local_info: nil,
        node_messages: [],
        error: nil,
        last_updated: nil,
        api_port: CorroPort.CorrosionClient.get_api_port(),
        phoenix_port: phoenix_port,
        refresh_interval: @refresh_interval
      })

    {:ok, fetch_cluster_data(socket)}
  end

  # Event handlers
  def handle_event("refresh", _params, socket) do
    Logger.debug("ClusterLive: 🔄 Manual refresh triggered")
    {:noreply, fetch_cluster_data(socket)}
  end

  # Private functions
  defp fetch_cluster_data(socket) do
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data()

    assign(socket, %{
      cluster_info: updates.cluster_info,
      local_info: updates.local_info,
      node_messages: updates.node_messages,
      error: updates.error,
      last_updated: updates.last_updated
    })
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:cluster} />

      <ClusterCards.cluster_header_simple />
      <ClusterCards.error_alerts error={@error} />
      <ClusterCards.status_cards_simple
        local_info={@local_info}
        cluster_info={@cluster_info}
        node_messages={@node_messages}
        last_updated={@last_updated}
        phoenix_port={@phoenix_port}
        api_port={@api_port}
        refresh_interval={@refresh_interval}
        error={@error}
      />

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

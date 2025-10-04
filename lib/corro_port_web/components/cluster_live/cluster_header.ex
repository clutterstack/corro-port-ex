defmodule CorroPortWeb.Components.ClusterLive.ClusterHeader do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders the cluster status page header with refresh all action.
  """
  def cluster_header(assigns) do
    ~H"""
    <.header>
      Corrosion Cluster Status
      <:subtitle>
        <div class="flex items-center gap-4">
          <span>Comprehensive cluster health and node connectivity monitoring</span>
        </div>
      </:subtitle>
      <:actions>
        <.button phx-click="refresh_all" class="btn btn-sm">
          <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh All
        </.button>
      </:actions>
    </.header>
    """
  end
end

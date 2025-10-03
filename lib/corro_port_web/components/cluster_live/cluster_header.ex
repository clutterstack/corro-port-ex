defmodule CorroPortWeb.Components.ClusterLive.ClusterHeader do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents
  alias CorroPortWeb.DisplayHelpers

  @doc """
  Renders the cluster status page header with refresh action buttons.
  """
  attr :dns_data, :map, required: true
  attr :cli_data, :map, required: true

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
        <div class="flex gap-2">
          <!-- Per-domain refresh buttons using helper functions -->
          <.button
            phx-click="refresh_dns"
            class={DisplayHelpers.refresh_button_class(@dns_data)}
          >
            <.icon name="hero-globe-alt" class="w-3 h-3 mr-1" />
            DNS
            <span :if={DisplayHelpers.show_warning?(@dns_data)} class="ml-1">⚠</span>
          </.button>

          <.button
            phx-click="refresh_cli"
            class={DisplayHelpers.refresh_button_class(@cli_data)}
          >
            <.icon name="hero-command-line" class="w-3 h-3 mr-1" />
            CLI
            <span :if={DisplayHelpers.show_warning?(@cli_data)} class="ml-1">⚠</span>
          </.button>

          <.button phx-click="refresh_all" class="btn btn-sm">
            <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh All
          </.button>
        </div>
      </:actions>
    </.header>
    """
  end
end

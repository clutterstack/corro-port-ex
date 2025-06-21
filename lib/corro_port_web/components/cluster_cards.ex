defmodule CorroPortWeb.ClusterCards do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents
  alias CorroPortWeb.DisplayHelpers

  @moduledoc """
  Function components for Corrosion cluster status using clean domain data.
  """

  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true
  attr :system_data, :map, required: true

  def cluster_header(assigns) do
    # Pre-compute button configurations using helper functions
    dns_button = DisplayHelpers.refresh_button_config(assigns.expected_data, "refresh_expected", "DNS", "hero-globe-alt")
    cli_button = DisplayHelpers.refresh_button_config(assigns.active_data, "refresh_active", "CLI", "hero-command-line")
    system_button = DisplayHelpers.system_button_config(assigns.system_data, "refresh_system", "System", "hero-server")

    assigns = assign(assigns, %{
      dns_button: dns_button,
      cli_button: cli_button,
      system_button: system_button
    })

    ~H"""
    <.header>
      Corrosion Cluster Status
      <:subtitle>
        <div class="flex items-center gap-4">
          <span>Monitoring cluster health and node connectivity</span>
        </div>
      </:subtitle>
      <:actions>
        <div class="flex gap-2">
          <!-- Per-domain refresh buttons using helper configurations -->
          <.action_button config={@dns_button} />
          <.action_button config={@cli_button} />
          <.action_button config={@system_button} />

          <.button phx-click="reset_tracking" class="btn btn-warning btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Reset
          </.button>

          <.button phx-click="send_message" variant="primary" class="btn-sm">
            <.icon name="hero-paper-airplane" class="w-3 h-3 mr-1" /> Send
          </.button>

          <.button phx-click="refresh_all" class="btn btn-sm">
            <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh All
          </.button>
        </div>
      </:actions>
    </.header>
    """
  end

  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true
  attr :system_data, :map, required: true

  def error_alerts(assigns) do
    # Pre-compute alert configurations using helper functions
    alerts = DisplayHelpers.build_all_alerts(assigns.expected_data, assigns.active_data, assigns.system_data)
    assigns = assign(assigns, :alerts, alerts)

    ~H"""
    <div class="space-y-2">
      <.single_alert :for={alert <- @alerts} config={alert} />
    </div>
    """
  end

  # Helper component for individual alerts
  defp single_alert(%{config: nil} = assigns), do: ~H""
  defp single_alert(assigns) do
    ~H"""
    <div class={@config.class}>
      <.icon name={@config.icon} class="w-5 h-5" />
      <div>
        <div class="font-semibold">{@config.title}</div>
        <div class="text-sm">{@config.message}</div>
      </div>
    </div>
    """
  end

  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true
  attr :system_data, :map, required: true
  attr :expected_regions, :list, required: true
  attr :active_regions, :list, required: true
  attr :last_updated, :any, required: true

  def enhanced_cluster_summary(assigns) do
    # Pre-compute all display data using helper functions
    summary_stats = DisplayHelpers.cluster_summary_stats(
      assigns.expected_data,
      assigns.active_data,
      assigns.system_data,
      assigns.expected_regions,
      assigns.active_regions
    )

    system_info = DisplayHelpers.system_info_details(assigns.system_data)
    last_updated_display = DisplayHelpers.format_timestamp(assigns.last_updated)

    assigns = assign(assigns, %{
      summary_stats: summary_stats,
      system_info: system_info,
      last_updated_display: last_updated_display
    })

    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-sm">
          <.icon name="hero-server-stack" class="w-4 h-4 mr-2" /> Cluster Summary
        </h3>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <!-- Expected Nodes -->
          <.stat_card
            title="Expected Nodes"
            display={@summary_stats.expected.display}
            description="{@summary_stats.expected.regions_count} regions"
          />

          <!-- Active Members -->
          <.stat_card
            title="Active Members"
            display={@summary_stats.active.display}
            description="{@summary_stats.active.regions_count} regions"
          />

          <!-- API Health -->
          <.stat_card
            title="API Health"
            display={@summary_stats.api_health}
            description={@summary_stats.api_health.description}
          />

          <!-- Message Activity -->
          <.stat_card
            title="Messages"
            display={@summary_stats.messages_count}
            class=""
            description="in database"
          />
        </div>

        <!-- System Info Details using helper function -->
        <.system_info_section :if={@system_info} system_info={@system_info} />

        <div class="divider my-2"></div>

        <div class="text-xs text-base-content/70">
          <strong>Last Updated:</strong> {@last_updated_display}
        </div>
      </div>
    </div>
    """
  end

  # Helper component for stat cards
  defp stat_card(assigns) do
    ~H"""
    <div class="stat bg-base-100 rounded-lg">
      <div class="stat-title text-xs">{@title}</div>
      <div class={"stat-value text-lg flex items-center #{@class}"}>
        {@display}
      </div>
      <div class="stat-desc text-xs">{@description}</div>
    </div>
    """
  end

  # Helper component for system info section
  defp system_info_section(assigns) do
    ~H"""
    <div class="mt-4 text-sm space-y-2">
      <div class="flex items-center justify-between">
        <strong>Total Active Nodes:</strong>
        <span class="font-semibold text-lg">
          {@system_info.total_active_nodes}
        </span>
      </div>

      <div class="flex items-center justify-between">
        <strong>Remote Members:</strong>
        <span>
          {@system_info.active_member_count}/{@system_info.member_count} active
        </span>
      </div>

      <div class="flex items-center justify-between">
        <strong>Tracked Peers:</strong>
        <span>{@system_info.peer_count}</span>
      </div>
    </div>
    """
  end

  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true
  attr :system_data, :map, required: true

  def cache_status_indicators(assigns) do
    # Pre-compute all cache status displays using helper function
    cache_status = DisplayHelpers.all_cache_status(assigns.expected_data, assigns.active_data, assigns.system_data)
    assigns = assign(assigns, :cache_status, cache_status)

    ~H"""
    <div class="flex gap-4 text-xs text-base-content/70">
      <.cache_item label="DNS Cache" status={@cache_status.dns} />
      <.cache_item label="CLI Cache" status={@cache_status.cli} />
      <.cache_item label="System Cache" status={@cache_status.system} />
    </div>
    """
  end

  # Helper component for individual cache status items
  defp cache_item(assigns) do
    ~H"""
    <div>
      <strong>{@label}:</strong>
      {@status}
    </div>
    """
  end

  # Helper component for action buttons with configurations
  defp action_button(assigns) do
    ~H"""
    <.button phx-click={@config.action} class={@config.class}>
      <.icon name={@config.icon} class="w-3 h-3 mr-1" />
      {@config.label}
      <span :if={@config.show_warning} class="ml-1">⚠</span>
    </.button>
    """
  end

end

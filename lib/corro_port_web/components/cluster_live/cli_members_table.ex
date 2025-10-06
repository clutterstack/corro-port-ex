defmodule CorroPortWeb.Components.ClusterLive.CLIMembersTable do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents
  alias CorroPortWeb.DisplayHelpers

  def display(assigns) do
    # Pre-compute display content using helper functions
    status_info =
      if assigns.cli_member_data do
        DisplayHelpers.build_cli_status_info(assigns.cli_member_data)
      else
        nil
      end

    assigns = assign(assigns, :status_info, status_info)

    ~H"""
    <!-- CLI Members Section -->
    <div class="card bg-base-100">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h3 class="card-title">
            <.icon name="hero-command-line" class="w-5 h-5 mr-2" /> CLI cluster members
          </h3>
          <div class="flex gap-3 items-center">
            <span :if={@cli_data.cache_status.last_updated} class="text-xs text-base-content/60">
              Updated {Calendar.strftime(@cli_data.cache_status.last_updated, "%H:%M:%S")}
            </span>
            <.button phx-click="refresh_cli" class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Refresh CLI Data
            </.button>
            <span
              :if={DisplayHelpers.show_fetching_spinner?(@cli_member_data)}
              class="flex items-center text-sm"
            >
              <div class="loading loading-spinner loading-sm mr-2"></div>
              Fetching...
            </span>
          </div>
        </div>
        
    <!-- Error Display -->
        <.cli_error_alert
          :if={DisplayHelpers.should_show_cli_error?(@cli_error)}
          cli_error={@cli_error}
        />
        
    <!-- CLI Results -->
        <.cli_results_section
          :if={DisplayHelpers.has_successful_cli_members?(@cli_member_data)}
          cli_member_data={@cli_member_data}
        />
        
    <!-- Empty State -->
        <.cli_empty_state :if={DisplayHelpers.show_cli_empty_state?(@cli_member_data, @cli_error)} />
        
    <!-- Loading State -->
        <.cli_loading_state :if={DisplayHelpers.show_cli_loading_state?(@cli_member_data)} />
      </div>
    </div>
    """
  end

  # Helper components extracted from template

  defp cli_error_alert(assigns) do
    error_config = DisplayHelpers.build_cli_error_config(assigns.cli_error)
    assigns = assign(assigns, :error_config, error_config)

    ~H"""
    <div class="alert alert-warning mb-4">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <div>
        <div class="font-semibold">{@error_config.title}</div>
        <div class="text-sm">{@error_config.message}</div>
      </div>
    </div>
    """
  end

  defp cli_results_section(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="overflow-x-auto">
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
            <tr :for={member <- @cli_member_data.members}>
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
    """
  end

  defp cli_empty_state(assigns) do
    ~H"""
    <div class="alert alert-info">
      <.icon name="hero-information-circle" class="w-5 h-5" />
      <span>No cluster members found - this appears to be a single node setup</span>
    </div>
    """
  end

  defp cli_loading_state(assigns) do
    ~H"""
    <div class="text-center py-4">
      <div class="loading loading-spinner loading-lg mb-2"></div>
      <div class="text-sm text-base-content/70">
        Initializing CLI member data...
      </div>
    </div>
    """
  end
end

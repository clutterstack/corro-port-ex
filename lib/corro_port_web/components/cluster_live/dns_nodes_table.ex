defmodule CorroPortWeb.Components.ClusterLive.DNSNodesTable do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents
  alias CorroPortWeb.DisplayHelpers

  def display(assigns) do
    # Pre-compute display content using helper functions
    dns_node_data =
      if assigns.dns_data do
        DisplayHelpers.build_dns_node_data(assigns.dns_data)
      else
        nil
      end

    status_info =
      if dns_node_data do
        DisplayHelpers.build_dns_status_info(dns_node_data)
      else
        nil
      end

    dns_error = DisplayHelpers.extract_dns_error(assigns.dns_data)

    assigns =
      assign(assigns, %{
        status_info: status_info,
        dns_node_data: dns_node_data,
        dns_error: dns_error
      })

    ~H"""
    <!-- DNS Nodes Section -->
    <div class="card bg-base-100">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h3 class="card-title">
            <.icon name="hero-globe-alt" class="w-5 h-5 mr-2" /> DNS-Discovered Nodes
          </h3>
          <div class="flex gap-3 items-center">
            <span :if={@dns_data.cache_status.last_updated} class="text-xs text-base-content/60">
              Updated {Calendar.strftime(@dns_data.cache_status.last_updated, "%H:%M:%S")}
            </span>
            <.button phx-click="refresh_dns" class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Refresh DNS Data
            </.button>
            <span
              :if={DisplayHelpers.show_fetching_spinner?(@dns_node_data)}
              class="flex items-center text-sm"
            >
              <div class="loading loading-spinner loading-sm mr-2"></div>
              Fetching...
            </span>
          </div>
        </div>
        
    <!-- Error Display -->
        <.dns_error_alert
          :if={DisplayHelpers.should_show_dns_error?(@dns_error)}
          dns_error={@dns_error}
        />
        
    <!-- DNS Results -->
        <.dns_results_section
          :if={DisplayHelpers.has_successful_dns_nodes?(@dns_node_data)}
          dns_node_data={@dns_node_data}
        />
        
    <!-- Empty State -->
        <.dns_empty_state :if={DisplayHelpers.show_dns_empty_state?(@dns_node_data, @dns_error)} />
        
    <!-- Loading State -->
        <.dns_loading_state :if={DisplayHelpers.show_dns_loading_state?(@dns_node_data)} />
      </div>
    </div>
    """
  end

  # Helper components extracted from template

  defp dns_error_alert(assigns) do
    error_config = DisplayHelpers.build_dns_error_config(assigns.dns_error)
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

  defp dns_results_section(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Region</th>
              <th>Machine ID</th>
              <th>Full Node ID</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={node <- @dns_node_data.nodes}>
              <td>
                <span class="badge badge-primary badge-sm">
                  {node["region"]}
                </span>
              </td>
              <td class="font-mono text-sm">
                {node["machine_id"]}
              </td>
              <td class="font-mono text-xs text-base-content/70">
                {node["full_id"]}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp dns_empty_state(assigns) do
    ~H"""
    <div class="alert alert-info">
      <.icon name="hero-information-circle" class="w-5 h-5" />
      <span>
        No expected nodes found from DNS - this appears to be a single node setup or DNS is not configured
      </span>
    </div>
    """
  end

  defp dns_loading_state(assigns) do
    ~H"""
    <div class="text-center py-4">
      <div class="loading loading-spinner loading-lg mb-2"></div>
      <div class="text-sm text-base-content/70">
        Initializing DNS node data...
      </div>
    </div>
    """
  end
end

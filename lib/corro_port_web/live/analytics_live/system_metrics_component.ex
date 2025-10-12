defmodule CorroPortWeb.AnalyticsLive.SystemMetricsComponent do
  @moduledoc """
  Phoenix Component for displaying system metrics.

  Shows memory usage and Erlang process counts for active cluster nodes.
  """

  use Phoenix.Component

  @doc """
  Renders the system metrics display showing memory and process counts.
  """
  attr :system_metrics, :list, required: true

  def system_metrics(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-lg mb-4">System Metrics</h3>

        <%= if @system_metrics != [] do %>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <!-- Memory Usage -->
            <div>
              <h4 class="font-medium mb-2">Memory Usage (MB)</h4>
              <div class="space-y-2">
                <%= for metric <- Enum.take(@system_metrics, 10) do %>
                  <div class="flex items-center justify-between text-sm">
                    <span class="text-base-content/70">{metric.node_id}</span>
                    <span class="font-medium">{metric.memory_mb} MB</span>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Process Count -->
            <div>
              <h4 class="font-medium mb-2">Erlang Processes</h4>
              <div class="space-y-2">
                <%= for metric <- Enum.take(@system_metrics, 10) do %>
                  <div class="flex items-center justify-between text-sm">
                    <span class="text-base-content/70">{metric.node_id}</span>
                    <span class="font-medium">{metric.erlang_processes}</span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% else %>
          <div class="text-base-content/50 text-center py-8">
            No system metrics available
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end

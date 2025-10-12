defmodule CorroPortWeb.AnalyticsLive.ActiveNodesComponent do
  @moduledoc """
  Phoenix Component for displaying active cluster nodes.

  Shows a grid of active nodes with their metadata including:
  - Node ID
  - Region
  - Phoenix port
  - Local node indicator
  """

  use Phoenix.Component

  @doc """
  Renders the active nodes grid showing cluster membership.
  """
  attr :active_nodes, :list, required: true

  def active_nodes_grid(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-6">
      <div class="card-body">
        <h3 class="card-title text-lg mb-4">Active Nodes</h3>

        <%= if @active_nodes != [] do %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for node <- @active_nodes do %>
              <div class="border border-base-300 rounded-lg p-3 bg-base-100">
                <div class="font-medium">{node.node_id}</div>
                <div class="text-sm text-base-content/70">
                  Region: {node.region || "Unknown"}
                </div>
                <%= if node.phoenix_port do %>
                  <div class="text-sm text-base-content/70">
                    Port: {node.phoenix_port}
                  </div>
                <% end %>
                <%= if node.is_local do %>
                  <div class="badge badge-info badge-sm mt-1">
                    Local Node
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="text-base-content/50 text-center py-4">
            No active nodes detected
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end

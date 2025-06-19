defmodule CorroPortWeb.CLIMembersTable do
use Phoenix.Component
  import CorroPortWeb.CoreComponents


  def display(assigns) do
~H"""


        <!-- CLI Members Section -->
      <div class="card bg-base-100">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h3 class="card-title">
              <.icon name="hero-command-line" class="w-5 h-5 mr-2" /> CLI cluster members
            </h3>
            <div class="flex gap-2">
              <.button phx-click="refresh_cli_members" class="btn btn-primary btn-sm">
                <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" />
                Refresh CLI Data
              </.button>
              <span :if={@cli_member_data && @cli_member_data.status == :fetching} class="flex items-center text-sm">
                <div class="loading loading-spinner loading-sm mr-2"></div>
                Fetching...
              </span>
            </div>
          </div>

          <!-- CLI Status Info -->
          <div :if={@cli_member_data} class="mb-4">
            <div class="flex items-center gap-4 text-sm">
              <div class="flex items-center gap-2">
                <span class="font-semibold">Status:</span>
                <span class={cli_status_badge_class(@cli_member_data.status)}>
                  {format_cli_status(@cli_member_data.status)}
                </span>
              </div>
              <div :if={@cli_member_data.last_updated}>
                <span class="font-semibold">Last Updated:</span>
                <span class="text-xs">{Calendar.strftime(@cli_member_data.last_updated, "%H:%M:%S")}</span>
              </div>
              <div>
                <span class="font-semibold">Members:</span>
                <span>{@cli_member_data.member_count}</span>
              </div>
            </div>
          </div>

          <!-- Error Display -->
          <div :if={@cli_error} class="alert alert-warning mb-4">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div>
              <div class="font-semibold">CLI Data Issue</div>
              <div class="text-sm">
                <%= case @cli_error do %>
                  <% {:cli_error, :timeout} -> %>
                    CLI command timed out after 15 seconds
                  <% {:cli_error, reason} -> %>
                    CLI command failed: #{inspect(reason)}
                  <% {:parse_error, _reason} -> %>
                    CLI command succeeded but output couldn't be parsed
                  <% {:service_unavailable, msg} -> %>
                    {msg}
                  <% _ -> %>
                    Unknown CLI error: #{inspect(@cli_error)}
                <% end %>
              </div>
            </div>
          </div>

          <!-- CLI Results -->
          <div :if={@cli_member_data && @cli_member_data.members != []} class="space-y-4">
            <div class="alert alert-success">
              <.icon name="hero-check-circle" class="w-5 h-5" />
              <span>Found {length(@cli_member_data.members)} cluster members via CLI</span>
            </div>

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

          <!-- Empty State -->
          <div :if={@cli_member_data && @cli_member_data.members == [] && !@cli_error} class="alert alert-info">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span>No cluster members found - this appears to be a single node setup</span>
          </div>

          <!-- Loading State -->
          <div :if={!@cli_member_data || @cli_member_data.status == :initializing} class="text-center py-4">
            <div class="loading loading-spinner loading-lg mb-2"></div>
            <div class="text-sm text-base-content/70">
              Initializing CLI member data...
            </div>
          </div>
        </div>
      </div>
"""

end

# Helper functions for CLI status display

  defp cli_status_badge_class(status) do
    base = "badge badge-sm"

    case status do
      :ok -> "#{base} badge-success"
      :fetching -> "#{base} badge-info"
      :error -> "#{base} badge-error"
      :unavailable -> "#{base} badge-warning"
      :initializing -> "#{base} badge-neutral"
      _ -> "#{base} badge-neutral"
    end
  end

  defp format_cli_status(status) do
    case status do
      :ok -> "Active"
      :fetching -> "Fetching"
      :error -> "Error"
      :unavailable -> "Unavailable"
      :initializing -> "Starting"
      _ -> "Unknown"
    end
  end
end

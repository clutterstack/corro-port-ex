defmodule CorroPortWeb.AnalyticsLive.ExperimentHistoryComponent do
  @moduledoc """
  Phoenix Component for rendering experiment history table.

  Displays up to 10 most recent experiments with:
  - Experiment ID
  - Start time and duration
  - Message and acknowledgment counts
  - View details button
  """

  use Phoenix.Component
  import CorroPortWeb.AnalyticsLive.Helpers

  @doc """
  Renders the experiment history table showing past experiments.
  """
  attr :experiment_history, :list, required: true
  attr :current_experiment, :string, default: nil
  attr :viewing_mode, :atom, default: :current
  attr :show_confirm_delete, :boolean, default: false
  attr :confirm_delete_experiment_id, :string, default: nil
  attr :show_confirm_clear, :boolean, default: false

  def experiment_history(assigns) do
    ~H"""
    <%= if @experiment_history != [] do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h3 class="card-title text-lg">Experiment History</h3>
            <div class="flex gap-2">
              <%= if @current_experiment && @viewing_mode == :historical do %>
                <button
                  phx-click="clear_view"
                  class="text-sm text-primary hover:text-primary-focus"
                >
                  Clear Selection
                </button>
              <% end %>
              <button
                phx-click="confirm_clear_all"
                class="btn btn-sm btn-error"
                title="Clear all experiment history"
              >
                Clear History
              </button>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300">
                  <th class="text-base-content">Experiment ID</th>
                  <th class="text-base-content">Started</th>
                  <th class="text-base-content">Duration</th>
                  <th class="text-base-content">Messages</th>
                  <th class="text-base-content">Acks</th>
                  <th class="text-base-content">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for exp <- Enum.take(@experiment_history, 10) do %>
                  <tr class={[
                    "hover:bg-base-300/50",
                    if(@current_experiment == exp.id, do: "bg-primary/10", else: "")
                  ]}>
                    <td class="font-mono">{exp.id}</td>
                    <td>
                      <%= if exp.time_range do %>
                        {format_datetime(exp.time_range.start)}
                      <% else %>
                        <span class="text-base-content/40">-</span>
                      <% end %>
                    </td>
                    <td>
                      <%= if exp.duration_seconds do %>
                        {exp.duration_seconds}s
                      <% else %>
                        <span class="text-base-content/40">-</span>
                      <% end %>
                    </td>
                    <td>{exp.send_count}</td>
                    <td>{exp.ack_count}</td>
                    <td>
                      <div class="flex gap-2">
                        <button
                          phx-click="view_experiment"
                          phx-value-experiment_id={exp.id}
                          class="text-primary hover:text-primary-focus text-sm"
                        >
                          View
                        </button>
                        <button
                          phx-click="confirm_delete_experiment"
                          phx-value-experiment_id={exp.id}
                          class="text-error hover:text-error-focus text-sm"
                          title="Delete this experiment"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <%= if length(@experiment_history) > 10 do %>
            <div class="mt-4 text-sm text-base-content/60 text-center">
              Showing 10 most recent experiments of {length(@experiment_history)} total
            </div>
          <% end %>
        </div>
      </div>

      <!-- Delete Single Experiment Confirmation Modal -->
      <%= if @show_confirm_delete && @confirm_delete_experiment_id do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg">Confirm Deletion</h3>
            <p class="py-4">
              Are you sure you want to delete experiment
              <span class="font-mono">{@confirm_delete_experiment_id}</span>?
              This will permanently remove all associated data.
            </p>
            <div class="modal-action">
              <button phx-click="cancel_delete" class="btn btn-ghost">Cancel</button>
              <button
                phx-click="delete_experiment"
                phx-value-experiment_id={@confirm_delete_experiment_id}
                class="btn btn-error"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Clear All History Confirmation Modal -->
      <%= if @show_confirm_clear do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg">Clear All History</h3>
            <p class="py-4">
              Are you sure you want to clear <strong>all experiment history</strong>?
              This will permanently delete all experiments and their data. This action cannot be undone.
            </p>
            <div class="modal-action">
              <button phx-click="cancel_clear_all" class="btn btn-ghost">Cancel</button>
              <button phx-click="clear_all_experiments" class="btn btn-error">
                Clear All
              </button>
            </div>
          </div>
        </div>
      <% end %>
    <% end %>
    """
  end
end

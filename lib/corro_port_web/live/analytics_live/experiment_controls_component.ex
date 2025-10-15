defmodule CorroPortWeb.AnalyticsLive.ExperimentControlsComponent do
  @moduledoc """
  Phoenix Component for experiment control panel.

  Provides start/stop controls and configuration options for experiments including:
  - Transport mode selection (Corrosion gossip vs PubSub direct)
  - Experiment ID input
  - Message count and interval configuration
  - Action buttons (Start, Stop, Refresh)
  - Status display with progress indicators
  """

  use Phoenix.Component
  import CorroPortWeb.AnalyticsLive.Helpers

  @doc """
  Renders the experiment control panel with start/stop buttons and configuration.
  """
  attr :current_experiment, :string, default: nil
  attr :aggregation_status, :atom, required: true
  attr :message_count, :integer, required: true
  attr :message_interval_ms, :integer, required: true
  attr :message_progress, :map, default: nil
  attr :refresh_interval, :integer, required: true
  attr :last_update, :any, default: nil
  attr :transport_mode, :atom, default: :corrosion
  attr :experiment_id, :string, default: ""

  def experiment_controls(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-6">
      <div class="card-body">
        <h3 class="card-title text-lg mb-4">Experiment Control</h3>

        <!-- Transport Mode Selection (Outside Form) -->
        <div class="mb-4" id="transport-mode-section">
          <label class="block text-sm font-medium text-base-content mb-2">
            Message Transport
          </label>
          <div class="flex gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="transport_mode_display"
                value="corrosion"
                checked={@transport_mode == :corrosion}
                class="radio radio-primary"
                disabled={@aggregation_status == :running}
                phx-click="update_transport_mode"
                phx-value-transport_mode="corrosion"
              />
              <span class="text-base-content">Corrosion (Gossip)</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="transport_mode_display"
                value="pubsub"
                checked={@transport_mode == :pubsub}
                class="radio radio-primary"
                disabled={@aggregation_status == :running}
                phx-click="update_transport_mode"
                phx-value-transport_mode="pubsub"
              />
              <span class="text-base-content">PubSub (Direct)</span>
            </label>
          </div>
          <p class="text-xs text-base-content/60 mt-1" id="transport-mode-help">
            <%= if @transport_mode == :corrosion do %>
              Messages propagate via Corrosion's gossip protocol (database replication)
            <% else %>
              Messages propagate via Phoenix.PubSub (direct BEAM messaging)
            <% end %>
          </p>
        </div>

        <form phx-submit="start_aggregation" phx-change="update_form" class="space-y-4" id="experiment-form">
          <!-- Hidden input to include transport_mode in form submission -->
          <input type="hidden" name="transport_mode" value={@transport_mode} />

          <!-- Experiment ID -->
          <div>
            <label class="block text-sm font-medium text-base-content mb-2">
              Experiment ID
            </label>
            <input
              type="text"
              name="experiment_id"
              id="experiment_id_input"
              placeholder="Enter experiment ID"
              value={@experiment_id}
              class="input input-bordered w-full"
              required
              disabled={@aggregation_status == :running}
            />
          </div>

          <!-- Message Sending Configuration -->
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-base-content mb-2">
                Number of Messages (0 = manual sending)
              </label>
              <input
                type="number"
                name="message_count"
                value={@message_count}
                min="0"
                max="1000"
                class="input input-bordered w-full"
                disabled={@aggregation_status == :running}
                phx-change="update_message_count"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content mb-2">
                Message Interval (ms)
              </label>
              <input
                type="number"
                name="message_interval_ms"
                value={@message_interval_ms}
                min="50"
                max="60000"
                step="50"
                class="input input-bordered w-full"
                disabled={@aggregation_status == :running}
                phx-change="update_message_interval"
              />
            </div>
          </div>

          <!-- Action Buttons -->
          <div class="flex items-center gap-4">
            <button
              type="submit"
              class="btn btn-primary disabled:opacity-50 disabled:cursor-not-allowed"
              disabled={@aggregation_status == :running}
            >
              Start Experiment
            </button>

            <button
              type="button"
              phx-click="stop_aggregation"
              class="btn btn-error disabled:opacity-50 disabled:cursor-not-allowed"
              disabled={@aggregation_status == :stopped}
            >
              Stop
            </button>

            <button
              type="button"
              phx-click="refresh_now"
              class="btn btn-neutral"
            >
              Refresh Now
            </button>
          </div>
        </form>

        <!-- Status Bar -->
        <div class="mt-4 flex flex-wrap items-center gap-4 pt-4 border-t border-base-300">
          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/70">Status:</span>
            <span class={[
              "badge",
              if(@aggregation_status == :running,
                do: "badge-success",
                else: "badge-ghost"
              )
            ]}>
              {String.capitalize(to_string(@aggregation_status))}
            </span>
          </div>

          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/70">Transport:</span>
            <span class={[
              "badge",
              if(@transport_mode == :pubsub, do: "badge-info", else: "badge-neutral")
            ]}>
              {if @transport_mode == :pubsub, do: "PubSub", else: "Corrosion"}
            </span>
          </div>

          <%= if @message_progress do %>
            <div class="flex items-center gap-2">
              <span class="text-sm text-base-content/70">Messages:</span>
              <span class="badge badge-info">
                {@message_progress.sent}/{@message_progress.total}
              </span>
              <%= if @message_progress.sent < @message_progress.total do %>
                <div class="w-32 bg-base-300 rounded-full h-2">
                  <div
                    class="bg-primary h-2 rounded-full transition-all duration-300"
                    style={"width: #{Float.round(@message_progress.sent / @message_progress.total * 100, 1)}%"}
                  >
                  </div>
                </div>
              <% else %>
                <span class="text-xs text-success font-medium">Complete</span>
              <% end %>
            </div>
          <% end %>

          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/70">Refresh:</span>
            <select
              phx-change="set_refresh_interval"
              name="interval"
              class="select select-bordered select-sm"
            >
              <option value="1000" selected={@refresh_interval == 1000}>1s</option>
              <option value="5000" selected={@refresh_interval == 5000}>5s</option>
              <option value="10000" selected={@refresh_interval == 10000}>10s</option>
              <option value="30000" selected={@refresh_interval == 30000}>30s</option>
            </select>
          </div>

          <%= if @last_update do %>
            <div class="text-sm text-base-content/60">
              Last update: {format_time(@last_update)}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end

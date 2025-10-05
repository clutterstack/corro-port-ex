defmodule CorroPortWeb.NodeLive.BootstrapConfigComponent do
  @moduledoc """
  Component for managing local node bootstrap configuration.

  This component provides UI for editing bootstrap hosts when running under Overmind,
  including restart coordination and rollback functionality.
  """
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  alias CorroPort.NodeConfig

  def bootstrap_config(assigns) do
    ~H"""
    <!-- Bootstrap Configuration (Overmind Only) -->
    <div class="card bg-base-100">
      <div class="card-body">
        <h3 class="card-title text-lg">
          Bootstrap Configuration (Local Node)
          <span :if={!@overmind_available} class="badge badge-warning badge-sm ml-2">
            Overmind Required
          </span>
          <span :if={@overmind_available && !@is_production} class="badge badge-info badge-sm ml-2">
            Development
          </span>
        </h3>

        <div :if={!@overmind_available} class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            This feature requires Overmind to manage the Corrosion process. Start the cluster with <code class="font-mono bg-base-300 px-1">./scripts/overmind-start.sh</code>
          </span>
        </div>

        <div :if={@overmind_available} class="space-y-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Current Bootstrap Hosts</span>
            </label>
            <div class="bg-base-200 p-3 rounded font-mono text-sm">
              {if @bootstrap_hosts == "", do: "(empty)", else: @bootstrap_hosts}
            </div>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">New Bootstrap Hosts (comma-separated)</span>
              <span class="label-text-alt">Format: host1:port1, host2:port2</span>
            </label>
            <input
              type="text"
              name="value"
              class="input input-bordered w-full font-mono text-sm"
              value={@bootstrap_input}
              phx-keyup="update_bootstrap_input"
              placeholder="app.internal:8787, other.internal:8787"
              disabled={@bootstrap_status == :restarting}
            />
          </div>

          <div class="flex gap-2">
            <button
              class="btn btn-primary"
              phx-click="update_bootstrap"
              disabled={@bootstrap_status == :restarting}
            >
              <.icon
                :if={@bootstrap_status == :restarting}
                name="hero-arrow-path"
                class="w-4 h-4 mr-2 animate-spin"
              />
              <.icon :if={@bootstrap_status != :restarting} name="hero-cog-6-tooth" class="w-4 h-4 mr-2" />
              {if @bootstrap_status == :restarting, do: "Restarting Corrosion...", else: "Update & Restart Corrosion"}
            </button>

            <button
              :if={@bootstrap_status in [:error, :timeout]}
              class="btn btn-warning"
              phx-click="rollback_bootstrap"
            >
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4 mr-2" />
              Rollback to Backup
            </button>
          </div>

          <div :if={@bootstrap_status == :restarting} class="alert alert-info">
            <.icon name="hero-arrow-path" class="w-5 h-5 animate-spin" />
            <span>Corrosion is restarting. This may take a few seconds...</span>
          </div>

          <div :if={@bootstrap_status == :ready} class="alert alert-success">
            <.icon name="hero-check-circle" class="w-5 h-5" />
            <span>Corrosion has restarted successfully!</span>
          </div>

          <div :if={@bootstrap_status == :timeout} class="alert alert-error">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              Corrosion restart timed out. The process may still be starting. Check logs or use the rollback button.
            </span>
          </div>

          <div class="text-xs text-base-content/70">
            <strong>Note:</strong>
            Updating bootstrap will regenerate the Corrosion config file and restart the Corrosion agent via Overmind. The Phoenix application will remain running.
            <span :if={!@is_production}>
              <br />
              <strong>Development:</strong>
              Config file: <code class="font-mono bg-base-300 px-1">{NodeConfig.get_config_path()}</code>
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end

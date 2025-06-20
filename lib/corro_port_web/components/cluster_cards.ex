defmodule CorroPortWeb.ClusterCards do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @moduledoc """
  Function components for Corrosion cluster status using clean domain data.
  """

  def cluster_header(assigns) do
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
          <!-- Per-domain refresh buttons -->
          <.button
            phx-click="refresh_expected"
            class={[
              "btn btn-xs",
              if(@expected_data && match?({:error, _}, @expected_data.nodes), do: "btn-error", else: "btn-outline")
            ]}
          >
            <.icon name="hero-globe-alt" class="w-3 h-3 mr-1" />
            DNS
            <span :if={@expected_data && match?({:error, _}, @expected_data.nodes)} class="ml-1">⚠</span>
          </.button>

          <.button
            phx-click="refresh_active"
            class={[
              "btn btn-xs",
              if(@active_data && match?({:error, _}, @active_data.members), do: "btn-error", else: "btn-outline")
            ]}
          >
            <.icon name="hero-command-line" class="w-3 h-3 mr-1" />
            CLI
            <span :if={@active_data && match?({:error, _}, @active_data.members)} class="ml-1">⚠</span>
          </.button>

          <.button
            phx-click="refresh_system"
            class={[
              "btn btn-xs",
              if(@system_data && @system_data.cache_status.error, do: "btn-error", else: "btn-outline")
            ]}
          >
            <.icon name="hero-server" class="w-3 h-3 mr-1" />
            System
            <span :if={@system_data && @system_data.cache_status.error} class="ml-1">⚠</span>
          </.button>

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
    ~H"""
    <div class="space-y-2">
      <!-- DNS Error -->
      <div :if={match?({:error, reason}, @expected_data.nodes)} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">DNS Discovery Failed</div>
          <div class="text-sm">
            Error: {format_error(reason)} - Expected regions may be incomplete
          </div>
        </div>
      </div>

      <!-- CLI Error -->
      <div :if={match?({:error, reason}, @active_data.members)} class="alert alert-error">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">CLI Data Failed</div>
          <div class="text-sm">
            Error: {format_error(reason)} - Active member list may be stale
          </div>
        </div>
      </div>

      <!-- System Error -->
      <div :if={@system_data.cache_status.error} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">System Data Issue</div>
          <div class="text-sm">
            Error: {format_error(@system_data.cache_status.error)} - Cluster info may be incomplete
          </div>
        </div>
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
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-sm">
          <.icon name="hero-server-stack" class="w-4 h-4 mr-2" /> Cluster Summary
        </h3>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <!-- Expected Nodes -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">Expected Nodes</div>
            <div class="stat-value text-lg flex items-center">
              <%= case @expected_data.nodes do %>
                <% {:ok, nodes} -> %>
                  {length(nodes)}
                <% {:error, _} -> %>
                  <span class="text-error">?</span>
              <% end %>
            </div>
            <div class="stat-desc text-xs">{length(@expected_regions)} regions</div>
          </div>

          <!-- Active Members -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">Active Members</div>
            <div class="stat-value text-lg flex items-center">
              <%= case @active_data.members do %>
                <% {:ok, members} -> %>
                  {length(members)}
                <% {:error, _} -> %>
                  <span class="text-error">?</span>
              <% end %>
            </div>
            <div class="stat-desc text-xs">{length(@active_regions)} regions</div>
          </div>

          <!-- Cluster Health -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">API Health</div>
            <div class="stat-value text-lg">
              <%= if @system_data.cluster_info do %>
                <span class="text-success">✓</span>
              <% else %>
                <span class="text-error">✗</span>
              <% end %>
            </div>
            <div class="stat-desc text-xs">
              <%= if @system_data.cluster_info do %>
                connected
              <% else %>
                failed
              <% end %>
            </div>
          </div>

          <!-- Message Activity -->
          <div class="stat bg-base-100 rounded-lg">
            <div class="stat-title text-xs">Messages</div>
            <div class="stat-value text-lg">{length(@system_data.latest_messages)}</div>
            <div class="stat-desc text-xs">in database</div>
          </div>
        </div>

        <!-- System Info Details -->
        <div :if={@system_data.cluster_info} class="mt-4 text-sm space-y-2">
          <div class="flex items-center justify-between">
            <strong>Total Active Nodes:</strong>
            <span class="font-semibold text-lg">
              {Map.get(@system_data.cluster_info, "total_active_nodes", 0)}
            </span>
          </div>

          <div class="flex items-center justify-between">
            <strong>Remote Members:</strong>
            <span>
              {Map.get(@system_data.cluster_info, "active_member_count", 0)}/{Map.get(
                @system_data.cluster_info,
                "member_count",
                0
              )} active
            </span>
          </div>

          <div class="flex items-center justify-between">
            <strong>Tracked Peers:</strong>
            <span>{Map.get(@system_data.cluster_info, "peer_count", 0)}</span>
          </div>

          <div class="divider my-2"></div>

          <div class="text-xs text-base-content/70">
            <strong>Last Updated:</strong> {format_timestamp(@last_updated)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true
  attr :system_data, :map, required: true

  def cache_status_indicators(assigns) do
    ~H"""
    <div class="flex gap-4 text-xs text-base-content/70">
      <div>
        <strong>DNS Cache:</strong>
        <%= case @expected_data.cache_status do %>
          <% %{last_updated: nil} -> %>
            Never loaded
          <% %{last_updated: updated, error: nil} -> %>
            Updated {Calendar.strftime(updated, "%H:%M:%S")}
          <% %{last_updated: updated, error: error} -> %>
            Failed at {Calendar.strftime(updated, "%H:%M:%S")} ({format_error(error)})
        <% end %>
      </div>

      <div>
        <strong>CLI Cache:</strong>
        <%= case @active_data.cache_status do %>
          <% %{last_updated: nil} -> %>
            Never loaded
          <% %{last_updated: updated, error: nil} -> %>
            Updated {Calendar.strftime(updated, "%H:%M:%S")}
          <% %{last_updated: updated, error: error} -> %>
            Failed at {Calendar.strftime(updated, "%H:%M:%S")} ({format_error(error)})
        <% end %>
      </div>

      <div>
        <strong>System Cache:</strong>
        <%= case @system_data.cache_status do %>
          <% %{last_updated: nil} -> %>
            Never loaded
          <% %{last_updated: updated, error: nil} -> %>
            Updated {Calendar.strftime(updated, "%H:%M:%S")}
          <% %{last_updated: updated, error: error} -> %>
            Failed at {Calendar.strftime(updated, "%H:%M:%S")} ({format_error(error)})
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions

  defp format_error(reason) do
    case reason do
      :dns_failed -> "DNS lookup failed"
      :cli_timeout -> "CLI command timed out"
      {:cli_failed, _} -> "CLI command failed"
      {:parse_failed, _} -> "Failed to parse CLI output"
      :service_unavailable -> "Service unavailable"
      {:cluster_api_failed, _} -> "Cluster API connection failed"
      {:fetch_exception, _} -> "System data fetch failed"
      _ -> "#{inspect(reason)}"
    end
  end

  defp format_timestamp(nil), do: "Unknown"

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> timestamp
    end
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_timestamp(_), do: "Unknown"
end

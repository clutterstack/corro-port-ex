defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPortWeb.{ClusterCards, MembersTable, DebugSection, NavTabs}
  alias CorroPort.CorrosionCLI

  # 5 minutes refresh interval
  @refresh_interval 300_000

  def mount(_params, _session, socket) do
    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000

    socket =
      assign(socket, %{
        page_title: "Cluster Status",
        cluster_info: nil,
        local_info: nil,
        node_messages: [],
        error: nil,
        last_updated: nil,
        api_port: CorroPort.CorrosionClient.get_api_port(),
        phoenix_port: phoenix_port,
        refresh_interval: @refresh_interval,
        # CLI-related state
        cli_members_task: nil,
        cli_members_data: nil,
        cli_members_loading: false,
        cli_members_error: nil
      })

    {:ok, fetch_cluster_data(socket)}
  end

  # Event handlers
  def handle_event("refresh", _params, socket) do
    Logger.debug("ClusterLive: 🔄 Manual refresh triggered")
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_event("fetch_cli_members", _params, socket) do
    Logger.debug("ClusterLive: 🔧 CLI cluster members fetch triggered")

    # Start the async task
    task = CorrosionCLI.cluster_members_async()

    # Schedule a check for task completion
    # Process.send_after(self(), :check_cli_task, 100)

    socket =
      socket
      |> assign(:cli_members_task, task)
      |> assign(:cli_members_loading, true)
      |> assign(:cli_members_error, nil)
      |> put_flash(:info, "Fetching cluster members via CLI...")

    {:noreply, socket}
  end

  def handle_event("clear_cli_data", _params, socket) do
    socket =
      socket
      |> assign(:cli_members_data, nil)
      |> assign(:cli_members_error, nil)
      |> assign(:cli_members_task, nil)
      |> assign(:cli_members_loading, false)

    {:noreply, socket}
  end

  # handle
  def handle_info({task_ref, {:ok, raw_output}}, socket) do
    Logger.debug("handling \{:ok, #{inspect(raw_output)}\} from task #{inspect(task_ref)}")
    CorroPort.CorrosionParser.parse_cluster_members(raw_output) |> dbg

    # Use the dedicated parser
    parsed_result =
      case CorroPort.CorrosionParser.parse_cluster_members(raw_output) do
        {:ok, []} ->
          Logger.info("ClusterLive: No cluster members found - single node setup")
          %{}

        {:ok, members} ->
          Logger.info("ClusterLive: Parsed some CLI members")
          members

        {:error, reason} ->
          Logger.warning("ClusterLive: Failed to parse CLI output: #{inspect(reason)}")
          %{parse_error: reason, raw_output: raw_output}
      end

    flash_message =
      case parsed_result do
        %{} -> "✅ CLI command successful - single node setup (no cluster members)"
        list when is_list(list) -> "✅ CLI cluster members fetched successfully!"
        %{parse_error: _} -> "⚠️ CLI command succeeded but output couldn't be parsed"
      end

    socket =
      socket
      |> assign(:cli_members_data, parsed_result)
      |> assign(:cli_members_loading, false)
      |> assign(:cli_members_task, nil)
      |> put_flash(:info, flash_message)

    {:noreply, socket}
  end

  # handle
  def handle_info({:DOWN, ref, :process, _pid, :normal}, socket) do
    Logger.info("Handled :DOWN message from #{inspect(ref)}")
    {:noreply, socket}
  end

  # Handle CLI task completion checking
  # def handle_info(:check_cli_task, socket) do
  #   Logger.debug("Handling :check_cli_task info")
  #   case socket.assigns.cli_members_task do
  #     nil ->
  #       # No task running
  #       {:noreply, socket}

  #     task ->
  #       case Task.yield(task, 0) do

  #         {_task, {:ok, raw_output}, socket} ->
  #         Logger.info("ClusterLive: ✅ CLI task completed successfully")

  #         # Use the dedicated parser
  #         parsed_result = case CorroPort.CorrosionParser.parse_cluster_members(raw_output) do
  #           {:ok, ""} ->
  #             Logger.info("ClusterLive: No cluster members found - single node setup")
  #             []
  #           {:ok, members} ->
  #             Logger.info("ClusterLive: Parsed some CLI members")
  #             members |> dbg
  #           {:error, reason} ->
  #             Logger.warning("ClusterLive: Failed to parse CLI output: #{inspect(reason)}")
  #             %{parse_error: reason, raw_output: raw_output}
  #         end

  #         flash_message = case parsed_result do
  #           [] -> "✅ CLI command successful - single node setup (no cluster members)"
  #           list when is_list(list) -> "✅ CLI cluster members fetched successfully!"
  #           %{parse_error: _} -> "⚠️ CLI command succeeded but output couldn't be parsed"
  #         end

  #         socket =
  #           socket
  #           |> assign(:cli_members_data, parsed_result)
  #           |> assign(:cli_members_loading, false)
  #           |> assign(:cli_members_task, nil)
  #           |> put_flash(:info, flash_message)

  #         {:noreply, socket}

  #         {:ok, {:error, reason}} ->
  #           # Task completed with error
  #           Logger.warning("ClusterLive: ❌ CLI task failed: #{inspect(reason)}")

  #           socket =
  #             socket
  #             |> assign(:cli_members_error, format_cli_error(reason))
  #             |> assign(:cli_members_loading, false)
  #             |> assign(:cli_members_task, nil)
  #             |> put_flash(:error, "❌ CLI command failed: #{format_cli_error(reason)}")

  #           {:noreply, socket}

  #         nil ->
  #           # Still running, check again later
  #           Process.send_after(self(), :check_cli_task, 500)
  #           {:noreply, socket}
  #       end
  #   end
  # end

  # Private functions
  defp fetch_cluster_data(socket) do
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data()

    assign(socket, %{
      cluster_info: updates.cluster_info,
      local_info: updates.local_info,
      node_messages: updates.node_messages,
      error: updates.error,
      last_updated: updates.last_updated
    })
  end

  # defp format_cli_error({:exit_code, code, message}) do
  #   "Exit code #{code}: #{String.slice(message, 0, 100)}"
  # end

  # defp format_cli_error(:timeout) do
  #   "Command timed out"
  # end

  # defp format_cli_error(reason) when is_binary(reason) do
  #   reason
  # end

  # defp format_cli_error(reason) do
  #   inspect(reason)
  # end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:cluster} />

      <ClusterCards.cluster_header_simple />
      <ClusterCards.error_alerts error={@error} />
      <ClusterCards.status_cards_simple
        local_info={@local_info}
        cluster_info={@cluster_info}
        node_messages={@node_messages}
        last_updated={@last_updated}
        phoenix_port={@phoenix_port}
        api_port={@api_port}
        refresh_interval={@refresh_interval}
        error={@error}
      />

    <!-- CLI Members Section -->
      <div class="card bg-base-100">
        <div class="card-body">
          <h3 class="card-title">
            <.icon name="hero-command-line" class="w-5 h-5 mr-2" /> CLI Cluster Members
          </h3>

          <div class="flex items-center gap-3 mb-4">
            <.button
              phx-click="fetch_cli_members"
              class="btn btn-primary btn-sm"
              disabled={@cli_members_loading}
            >
              <.icon name="hero-command-line" class="w-4 h-4 mr-2" />
              {if @cli_members_loading, do: "Fetching...", else: "Fetch CLI Members"}
            </.button>

            <.button
              :if={@cli_members_data || @cli_members_error}
              phx-click="clear_cli_data"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-x-mark" class="w-4 h-4 mr-2" /> Clear
            </.button>

            <div :if={@cli_members_loading} class="flex items-center">
              <div class="loading loading-spinner loading-sm mr-2"></div>
              <span class="text-sm text-base-content/70">Running CLI command...</span>
            </div>
          </div>

    <!-- CLI Results -->
          <div :if={@cli_members_data && is_list(@cli_members_data)} class="space-y-4">
            <div :if={@cli_members_data == []} class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>No cluster members found - this appears to be a single node setup</span>
            </div>

            <div :if={@cli_members_data != []} class="alert alert-success">
              <.icon name="hero-check-circle" class="w-5 h-5" />
              <span>Found {length(@cli_members_data)} cluster members via CLI</span>
            </div>

            <div :if={@cli_members_data != []} class="overflow-x-auto">
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
                  <tr :for={member <- @cli_members_data}>
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

    <!-- Parse Error Display -->
          <div
            :if={
              @cli_members_data && is_map(@cli_members_data) &&
                Map.has_key?(@cli_members_data, :parse_error)
            }
            class="space-y-4"
          >
            <div class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>CLI command succeeded but failed to parse output</span>
            </div>

            <details class="collapse collapse-arrow bg-base-200">
              <summary class="collapse-title">Raw CLI Output</summary>
              <div class="collapse-content">
                <pre class="bg-base-300 p-4 rounded text-xs overflow-auto">{@cli_members_data.raw_output}</pre>
              </div>
            </details>

            <details class="collapse collapse-arrow bg-base-200">
              <summary class="collapse-title">Parse Error Details</summary>
              <div class="collapse-content">
                <pre class="bg-base-300 p-4 rounded text-xs overflow-auto">{inspect(@cli_members_data.parse_error, pretty: true)}</pre>
              </div>
            </details>
          </div>

    <!-- Error Display -->
          <div :if={@cli_members_error} class="alert alert-error">
            <.icon name="hero-exclamation-circle" class="w-5 h-5" />
            <div>
              <div class="font-semibold">CLI Command Failed</div>
              <div class="text-sm">{@cli_members_error}</div>
            </div>
          </div>

    <!-- Help Text -->
          <div
            :if={!@cli_members_data && !@cli_members_error && !@cli_members_loading}
            class="text-center py-4"
          >
            <.icon name="hero-command-line" class="w-8 h-8 mx-auto text-base-content/30 mb-2" />
            <div class="text-sm text-base-content/70">
              Click "Fetch CLI Members" to run
              <code class="bg-base-300 px-1 rounded">corrosion cluster members</code>
            </div>
            <div class="text-xs text-base-content/50 mt-1">
              This uses the CLI directly instead of the HTTP API
            </div>
          </div>
        </div>
      </div>

      <MembersTable.cluster_members_table cluster_info={@cluster_info} />

      <DebugSection.debug_section
        cluster_info={@cluster_info}
        local_info={@local_info}
        node_messages={@node_messages}
      />
    </div>
    """
  end

  # Helper function for timestamp formatting
  # defp format_timestamp(nil), do: "Never"

  # defp format_timestamp(ts) when is_integer(ts) do
  #   # Corrosion timestamps are often in nanoseconds
  #   seconds = div(ts, 1_000_000_000)

  #   case DateTime.from_unix(seconds) do
  #     {:ok, dt} -> Calendar.strftime(dt, "%m-%d %H:%M:%S")
  #     _ -> "Invalid"
  #   end
  # end

  # defp format_timestamp(_), do: "Unknown"
end

defmodule CorroPortWeb.NodeLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{NodeConfig, ConnectionManager, ConfigManager, ClusterConfigCoordinator}
  alias CorroPortWeb.NavTabs
  alias CorroPortWeb.NodeLive.BootstrapConfigComponent

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to any relevant updates
      Phoenix.PubSub.subscribe(CorroPort.PubSub, "node_updates")
    end

    # Get current bootstrap config
    bootstrap_hosts =
      case ConfigManager.get_current_bootstrap() do
        {:ok, hosts} -> Enum.join(hosts, ", ")
        {:error, _} -> ""
      end

    # Check if running under overmind (production or local overmind cluster)
    overmind_available = ConfigManager.running_under_overmind?()

    socket =
      assign(socket, %{
        page_title: "Node Information",
        node_info: nil,
        config_info: nil,
        corro_config_path: NodeConfig.get_config_path(),
        db_info: nil,
        process_info: nil,
        file_info: nil,
        api_cx_test: nil,
        error: nil,
        loading: true,
        last_updated: nil,
        # Bootstrap configuration (local node)
        bootstrap_hosts: bootstrap_hosts,
        bootstrap_input: bootstrap_hosts,
        bootstrap_status: nil,
        overmind_available: overmind_available,
        is_production: NodeConfig.production?(),
        # Cluster-wide configuration
        # :single or :all
        cluster_config_mode: :single,
        cluster_configs: [],
        cluster_config_input: bootstrap_hosts,
        selected_node_id: nil,
        active_nodes: [],
        # Cluster readiness tracking
        # nil | %{ready: bool, ready_count: N, total: N, ...}
        cluster_readiness_status: nil,
        # Track which nodes were updated for readiness check
        updated_node_ids: []
      })

    {:ok, fetch_node_data(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_node_data(socket)}
  end

  def handle_event("test_local_connection", _params, socket) do
    Logger.debug("NodeLive: Testing local Corrosion API connection.")

    # Run the test and update the socket with results
    test_result = perform_local_api_cx_test()
    Logger.debug("API responded OK")

    socket =
      socket
      |> assign(:api_cx_test, test_result)
      |> put_flash(
        if(test_result.success, do: :info, else: :error),
        test_result.flash_message
      )

    {:noreply, socket}
  end

  def handle_event("view_config", _params, socket) do
    config_path = socket.assigns.corro_config_path

    case File.read(config_path) do
      {:ok, content} ->
        Logger.info("Read config file: #{inspect(content)}")
        socket = put_flash(socket, :info, "Config content:\n#{content}")
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Couldn't read config file: #{inspect(reason)}")
        socket = put_flash(socket, :error, "Failed to read config: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("update_bootstrap_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :bootstrap_input, value)}
  end

  def handle_event("update_cluster_config_input", %{"bootstrap_hosts" => value}, socket) do
    {:noreply, assign(socket, :cluster_config_input, value)}
  end

  def handle_event("set_cluster_mode", %{"mode" => mode}, socket) do
    mode_atom = String.to_existing_atom(mode)
    {:noreply, assign(socket, :cluster_config_mode, mode_atom)}
  end

  def handle_event("select_node", %{"node_id" => node_id}, socket) do
    # Normalize empty string to nil
    node_id = if node_id == "", do: nil, else: node_id

    # Note: We no longer pre-populate the config input from the node_configs table
    # since we're using PubSub-based coordination instead. User must enter the desired
    # bootstrap config manually.

    socket =
      socket
      |> assign(:selected_node_id, node_id)
      |> assign(:cluster_config_input, "")

    {:noreply, socket}
  end

  def handle_event("update_cluster_config", params, socket) do
    Logger.info("Updating cluster configuration...")

    bootstrap_hosts = Map.get(params, "bootstrap_hosts", "")

    result =
      case socket.assigns.cluster_config_mode do
        :all ->
          # Use PubSub-based coordination for cluster-wide updates
          ClusterConfigCoordinator.broadcast_config_update(bootstrap_hosts)

        :single ->
          if socket.assigns.selected_node_id do
            # Use PubSub-based coordination for single-node updates
            ClusterConfigCoordinator.broadcast_config_update_to_node(
              socket.assigns.selected_node_id,
              bootstrap_hosts
            )
          else
            {:error, "No node selected"}
          end
      end

    socket =
      case result do
        # All nodes update via PubSub - returns connected Elixir nodes
        {:ok, elixir_nodes} when is_list(elixir_nodes) ->
          Logger.info(
            "Config update broadcast to #{length(elixir_nodes)} Elixir nodes: #{inspect(elixir_nodes)}"
          )

          # Start status polling to track update progress
          Process.send_after(self(), {:check_update_status, elixir_nodes, 0}, 1000)

          initial_status = %{
            ready: false,
            ready_count: 0,
            total: length(elixir_nodes),
            ready_nodes: [],
            missing_nodes: elixir_nodes
          }

          socket
          |> assign(:updated_node_ids, elixir_nodes)
          |> assign(:cluster_readiness_status, initial_status)
          |> put_flash(
            :info,
            "Config update broadcast to #{length(elixir_nodes)} nodes. Waiting for completion..."
          )
          |> fetch_cluster_configs()

        # Single node update (no node_ids list)
        {:ok, message} ->
          socket
          |> put_flash(:info, message)
          |> fetch_cluster_configs()

        {:error, reason} ->
          put_flash(socket, :error, "Failed to update config: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("refresh_cluster_configs", _params, socket) do
    {:noreply, fetch_cluster_configs(socket)}
  end

  def handle_event("update_bootstrap", _params, socket) do
    Logger.info("Updating bootstrap configuration...")

    case ConfigManager.update_bootstrap(socket.assigns.bootstrap_input, true) do
      {:ok, message} ->
        # Wait for Corrosion to restart and become responsive
        socket =
          socket
          |> assign(:bootstrap_status, :restarting)
          |> put_flash(:info, "#{message}. Waiting for Corrosion to restart...")

        # Schedule a delayed check for Corrosion connectivity
        Process.send_after(self(), :check_corrosion_ready, 2000)

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to update bootstrap: #{inspect(reason)}")

        socket =
          socket
          |> assign(:bootstrap_status, :error)
          |> put_flash(:error, "Failed to update bootstrap: #{reason}")

        {:noreply, socket}
    end
  end

  def handle_event("rollback_bootstrap", _params, socket) do
    Logger.info("Rolling back bootstrap configuration...")

    case ConfigManager.rollback_config() do
      {:ok, message} ->
        socket =
          socket
          |> assign(:bootstrap_status, :rolled_back)
          |> put_flash(:info, message)
          |> fetch_node_data()

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Rollback failed: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_info(:check_corrosion_ready, socket) do
    case ConfigManager.wait_for_corrosion(10, 1000) do
      {:ok, message} ->
        Logger.info("Corrosion is ready: #{message}")

        socket =
          socket
          |> assign(:bootstrap_status, :ready)
          |> put_flash(:info, "Corrosion has restarted successfully!")
          |> fetch_node_data()

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Corrosion did not become ready: #{reason}")

        socket =
          socket
          |> assign(:bootstrap_status, :timeout)
          |> put_flash(
            :error,
            "Corrosion restart timed out. Check logs or try rollback."
          )

        {:noreply, socket}
    end
  end

  def handle_info({:check_update_status, expected_elixir_nodes, attempt}, socket) do
    # 60 seconds total (1s intervals)
    max_attempts = 60
    status_map = ClusterConfigCoordinator.get_update_status()

    Logger.debug(
      "Update status check (attempt #{attempt + 1}/#{max_attempts}): #{inspect(status_map)}"
    )

    # Count successes and failures
    success_nodes =
      Enum.filter(status_map, fn {_node, info} -> info.status == :success end)
      |> Enum.map(fn {node, _} -> node end)

    failed_nodes =
      Enum.filter(status_map, fn {_node, info} -> info.status == :error end)
      |> Enum.map(fn {node, _} -> node end)

    pending_nodes =
      Enum.filter(status_map, fn {_node, info} -> info.status == :pending end)
      |> Enum.map(fn {node, _} -> node end)

    total = length(expected_elixir_nodes)
    ready_count = length(success_nodes)

    display_status = %{
      ready: ready_count == total && Enum.empty?(failed_nodes),
      ready_count: ready_count,
      total: total,
      ready_nodes: Enum.map(success_nodes, &Atom.to_string/1),
      missing_nodes: Enum.map(pending_nodes ++ failed_nodes, &Atom.to_string/1)
    }

    socket = assign(socket, :cluster_readiness_status, display_status)

    cond do
      # All nodes succeeded
      ready_count == total && Enum.empty?(failed_nodes) ->
        Logger.info("Cluster config update complete: All #{total} nodes succeeded")

        socket =
          socket
          |> assign(:cluster_readiness_status, nil)
          |> assign(:updated_node_ids, [])
          |> put_flash(:info, "Cluster config updated successfully on all #{total} nodes!")

        {:noreply, socket}

      # Some nodes failed
      not Enum.empty?(failed_nodes) && Enum.empty?(pending_nodes) ->
        Logger.error("Cluster config update failed on some nodes: #{inspect(failed_nodes)}")

        socket =
          socket
          |> put_flash(
            :error,
            "Config update failed on #{length(failed_nodes)} nodes: #{inspect(failed_nodes)}"
          )

        {:noreply, socket}

      # Timeout waiting for pending nodes
      attempt >= max_attempts ->
        Logger.warning(
          "Cluster config update timeout. Success: #{ready_count}/#{total}, Pending: #{inspect(pending_nodes)}, Failed: #{inspect(failed_nodes)}"
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Update timeout. #{ready_count}/#{total} succeeded. Pending: #{Enum.join(Enum.map(pending_nodes, &Atom.to_string/1), ", ")}"
          )

        {:noreply, socket}

      # Keep polling
      true ->
        Process.send_after(
          self(),
          {:check_update_status, expected_elixir_nodes, attempt + 1},
          1000
        )

        {:noreply, socket}
    end
  end

  # Private functions

  defp perform_local_api_cx_test do
    start_time = System.monotonic_time(:millisecond)

    if ConnectionManager.test_connection() == :ok do
      end_time = System.monotonic_time(:millisecond)
      response_time = end_time - start_time

      %{
        success: true,
        flash_message: "✅ Corrosion API is responding to queries",
        response_time_ms: response_time,
        timestamp: DateTime.utc_now(),
        details: "Responded in #{response_time}ms"
      }
    else
      end_time = System.monotonic_time(:millisecond)
      response_time = end_time - start_time

      %{
        success: false,
        flash_message: "❌ Local Corrosion API connection failed.",
        response_time_ms: response_time,
        timestamp: DateTime.utc_now(),
        details: "Check logs",
        error: "this is an error field"
      }
    end
  end

  defp fetch_node_data(socket) do
    Logger.info("NodeLive: Fetching comprehensive node data...")

    # Gather all the information
    node_info = get_node_info()
    config_info = get_config_info()

    conn = ConnectionManager.get_connection()

    # Fetch database info
    db_info =
      case CorroClient.get_database_info(conn) do
        {:ok, info} -> info
        {:error, _} -> %{}
      end

    process_info = get_process_info()
    file_info = get_file_info()
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    socket
    |> assign(%{
      node_info: node_info,
      local_node_id: local_node_id,
      config_info: config_info,
      db_info: db_info,
      process_info: process_info,
      file_info: file_info,
      loading: false,
      last_updated: DateTime.utc_now(),
      error: nil
    })
    |> fetch_cluster_configs()
  end

  defp fetch_cluster_configs(socket) do
    # Get all node configs from node_configs table
    cluster_configs =
      case ConfigManager.get_all_node_configs() do
        {:ok, configs} -> configs
        {:error, _} -> []
      end

    # Get active nodes with friendly labels
    active_nodes = get_active_nodes_with_labels()

    socket
    |> assign(:cluster_configs, cluster_configs)
    |> assign(:active_nodes, active_nodes)
  end

  defp get_active_nodes_with_labels do
    # Get CLI members (has UUIDs)
    cli_members =
      case CorroPort.CLIClusterData.get_members() do
        %{members: members} when is_list(members) -> members
        _ -> []
      end

    # Get node configs (has UUID -> node_id mapping)
    node_configs =
      case ConfigManager.get_all_node_configs() do
        {:ok, configs} -> configs
        {:error, _} -> []
      end

    # Build UUID -> node_id map
    uuid_to_node_id =
      Map.new(node_configs, fn config ->
        {config.corrosion_actor_id, config.node_id}
      end)

    # Map CLI members to {node_id, label} tuples
    Enum.map(cli_members, fn member ->
      uuid = Map.get(member, "id", "unknown")
      addr = Map.get(member, "display_addr", "")

      # Try to find friendly node_id, fallback to UUID
      case Map.get(uuid_to_node_id, uuid) do
        nil ->
          # Fallback: use UUID as node_id (won't match ConfigSubscriber, but at least visible)
          %{node_id: uuid, label: addr}

        node_id ->
          # Best: use actual node_id that ConfigSubscriber expects
          %{node_id: node_id, label: "#{node_id} (#{addr})"}
      end
    end)
  end

  defp get_node_info do
    node_config = NodeConfig.app_node_config()

    %{
      elixir_node: Node.self(),
      corrosion_node_id: NodeConfig.get_corrosion_node_id(),
      phoenix_port: Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port],
      gossip_port: node_config[:corrosion_gossip_port],
      hostname:
        case :inet.gethostname() do
          {:ok, hostname} -> to_string(hostname)
          _ -> "unknown"
        end,
      elixir_version: System.version(),
      otp_release: System.otp_release(),
      uptime: get_uptime()
    }
  end

  defp get_config_info do
    node_config = NodeConfig.app_node_config()
    config_path = NodeConfig.get_config_path()

    # Read the actual config file content
    config_content =
      case File.read(config_path) do
        {:ok, content} -> content
        {:error, reason} -> "Error reading config: #{inspect(reason)}"
      end

    %{
      config_path: config_path,
      config_exists: File.exists?(config_path),
      config_content: config_content,
      config_size: get_file_size(config_path),
      config_modified: get_file_modified(config_path),
      # Convert keyword list to map for JSON encoding
      raw_node_config: safe_inspect(node_config),
      application_env: %{
        node_config: safe_inspect(Application.get_env(:corro_port, :node_config)),
        dev_routes: Application.get_env(:corro_port, :dev_routes, false),
        endpoint_config: safe_inspect(Application.get_env(:corro_port, CorroPortWeb.Endpoint))
      }
    }
  end

  # Safe fallback that always produces JSON-serializable output
  defp safe_inspect(data) do
    inspect(data, pretty: true, limit: :infinity)
  end

  defp get_process_info do
    # Get information about the current Elixir processes
    processes = Process.list()

    %{
      total_processes: length(processes),
      memory_usage: :erlang.memory(),
      supervisors: get_supervisor_info()
    }
  end

  defp get_supervisor_info do
    # Get info about supervision tree
    try do
      children = Supervisor.which_children(CorroPort.Supervisor)

      Enum.map(children, fn {id, pid, type, modules} ->
        %{
          id: id,
          pid: inspect(pid),
          type: type,
          modules: modules,
          status: if(is_pid(pid) and Process.alive?(pid), do: :alive, else: :dead)
        }
      end)
    catch
      _ -> []
    end
  end

  defp get_file_info do
    # Get corrosion files from source of truth -- the corrosion config file as
    # generated by NodeConfig.
    corro_node_ex = NodeConfig.get_corrosion_node_id()

    files_to_check = [
      {"Config File", NodeConfig.get_config_path()},
      {"Database File", "corrosion/#{corro_node_ex}.db"},
      {"Database WAL", "corrosion/#{corro_node_ex}.db-wal"},
      {"Database SHM", "corrosion/#{corro_node_ex}.db-shm"},
      {"Corrosion Binary", Application.get_env(:corro_port, :node_config)[:corrosion_binary]}
    ]

    Enum.map(files_to_check, fn {name, path} ->
      %{
        name: name,
        path: path,
        exists: File.exists?(path),
        size: get_file_size(path),
        modified: get_file_modified(path),
        permissions: get_file_permissions(path)
      }
    end)
  end

  # Helper functions

  defp get_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    seconds = div(uptime_ms, 1000)

    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    "#{hours}h #{minutes}m #{secs}s"
  end

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> "#{size} bytes"
      _ -> "N/A"
    end
  end

  defp get_file_modified(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        mtime
        |> NaiveDateTime.from_erl!()
        |> DateTime.from_naive!("Etc/UTC")
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

      _ ->
        "N/A"
    end
  end

  defp get_file_permissions(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        # Convert to octal string representation
        Integer.to_string(mode, 8) |> String.slice(-3..-1)

      _ ->
        "N/A"
    end
  end

  defp format_memory(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_memory(_), do: "N/A"

  defp connectivity_status(nil) do
    %{
      icon: "hero-question-mark-circle",
      label: "Connectivity test not run yet",
      class: "text-base-content/70",
      detail: nil
    }
  end

  defp connectivity_status(%{success: true} = test) do
    detail =
      [
        test.response_time_ms && "#{test.response_time_ms}ms",
        format_test_timestamp(test.timestamp)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" | ")

    %{
      icon: "hero-signal",
      label: "Connected",
      class: "text-success",
      detail: if(detail == "", do: nil, else: "| " <> detail)
    }
  end

  defp connectivity_status(%{success: false} = test) do
    detail =
      [
        test.response_time_ms && "#{test.response_time_ms}ms",
        format_test_timestamp(test.timestamp),
        test.details
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" | ")

    %{
      icon: "hero-exclamation-triangle",
      label: "Connection failed",
      class: "text-error",
      detail: if(detail == "", do: nil, else: "| " <> detail)
    }
  end

  defp format_test_timestamp(nil), do: nil

  defp format_test_timestamp(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%H:%M:%S UTC")
  end

  defp cluster_readiness_icon(%{ready: true}), do: "hero-check-circle"
  defp cluster_readiness_icon(_), do: "hero-arrow-path"

  defp cluster_readiness_icon_class(%{ready: true}), do: "w-5 h-5"
  defp cluster_readiness_icon_class(_), do: "w-5 h-5 animate-spin"

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:node} />

      <.header>
        Node Information
        <:subtitle>
          About this node and its Corrosion and Elixir configuration
        </:subtitle>
        <:actions>
          <.button phx-click="refresh" variant="primary">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Refresh
          </.button>
          <.button phx-click="test_local_connection" class="btn btn-secondary">
            <.icon name="hero-signal" class="w-4 h-4 mr-2" /> Test Local API
          </.button>
        </:actions>
      </.header>

      <.connection_indicator api_cx_test={@api_cx_test} />

    <!-- Loading State -->
      <div :if={@loading} class="flex items-center justify-center py-8">
        <div class="loading loading-spinner loading-lg"></div>
        <span class="ml-4">Loading node information...</span>
      </div>

    <!-- Error State -->
      <div :if={@error} class="alert alert-error">
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <span>{@error}</span>
      </div>

    <!-- Node Information Cards -->
      <div :if={!@loading} class="grid grid-cols-1 lg:grid-cols-2 gap-6">

    <!-- The Elixir Application -->
        <div class="card bg-base-100">
          <div class="card-body">
            <h3 class="card-title text-lg">The Elixir Application</h3>
            <div :if={@node_info} class="space-y-3">
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div><strong>Elixir Node name:</strong></div>
                <div class="font-mono text-xs">{@node_info.elixir_node}</div>

                <div><strong>Elixir app's name for the local Corrosion node:</strong></div>
                <div class="font-mono">{@node_info.corrosion_node_id}</div>

                <div><strong>Hostname from :inet.gethostname():</strong></div>
                <div>{@node_info.hostname}</div>

                <div><strong>Erlang node uptime by :erlang.statistics(:wall_clock):</strong></div>
                <div>{@node_info.uptime}</div>
              </div>
            </div>

            <div :if={@node_info} class="space-y-3">
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div><strong>Phoenix HTTP port:</strong></div>
                <div class="font-mono">
                  {@node_info.phoenix_port}
                </div>
              </div>
            </div>
          </div>
        </div>

    <!-- Config from Application Environment -->
        <div class="card bg-base-100">
          <div class="card-body">
            <div :if={@config_info} class="space-y-3">
              <h3 class="card-title text-lg">Config from Application Environment:</h3>
              <pre class="bg-base-300 p-4 rounded text-xs overflow-auto">
                <%= @config_info.raw_node_config %>
              </pre>
            </div>
          </div>
        </div>

    <!-- Process Information -->
        <div class="card bg-base-100">
          <div class="card-body">
            <h3 class="card-title text-lg">Erlang Processes</h3>
            <div :if={@process_info} class="space-y-3">
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div><strong>Total Processes:</strong></div>
                <div>{@process_info.total_processes}</div>

                <div><strong>Memory Usage by :erlang.memory():</strong></div>
                <div>{format_memory(@process_info.memory_usage[:total])}</div>
              </div>

    <!-- Supervisor Children -->
              <div :if={@process_info.supervisors != []} class="mt-4">
                <h4 class="font-semibold text-sm mb-2">Supervisor Children:</h4>
                <div class="space-y-1">
                  <div
                    :for={child <- @process_info.supervisors}
                    class="flex items-center justify-between text-xs"
                  >
                    <span class="font-mono">{child.id}</span>
                    <span class={
                      if child.status == :alive,
                        do: "badge badge-success badge-xs",
                        else: "badge badge-error badge-xs"
                    }>
                      {child.status}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

    <!-- Corrosion Config File -->
        <div class="card bg-base-100">
          <div class="card-body">
            <h3 class="card-title text-lg">Corrosion Configuration</h3>
            <div :if={@config_info.config_exists}>
              <h4 class="font-semibold mb-2">Corrosion Config File: {@config_info.config_path}</h4>
              <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= @config_info.config_content %></pre>
            </div>
            <div :if={@config_info.config_exists} class="grid grid-cols-2 gap-2 text-xs mt-2">
              <div><strong>Size:</strong> {@config_info.config_size}</div>
              <div><strong>Modified:</strong> {@config_info.config_modified}</div>
            </div>
          </div>
        </div>
      </div>

      <BootstrapConfigComponent.bootstrap_config
        bootstrap_hosts={@bootstrap_hosts}
        bootstrap_input={@bootstrap_input}
        bootstrap_status={@bootstrap_status}
        overmind_available={@overmind_available}
        is_production={@is_production}
      />

    <!-- Cluster-wide Configuration Management -->
      <div class="card bg-base-100">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h3 class="card-title text-lg">
              Cluster-wide Configuration
              <span class="badge badge-primary badge-sm ml-2">
                Distributed via Corrosion
              </span>
            </h3>
            <button class="btn btn-sm btn-ghost" phx-click="refresh_cluster_configs">
              <.icon name="hero-arrow-path" class="w-4 h-4" />
            </button>
          </div>

          <div class="alert alert-info mb-4">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <div class="text-sm">
              <p>Changes are broadcast via Elixir PubSub to all nodes in the cluster.</p>
              <p>
                Each node's ClusterConfigCoordinator applies changes locally and restarts Corrosion.
              </p>
              <p class="text-warning mt-1">
                This approach is safe even if Corrosion gossip is broken by bad bootstrap config.
              </p>
            </div>
          </div>

    <!-- Mode Selection -->
          <div class="flex gap-2 mb-4">
            <button
              class={[
                "btn",
                if(@cluster_config_mode == :all, do: "btn-primary", else: "btn-outline")
              ]}
              phx-click="set_cluster_mode"
              phx-value-mode="all"
            >
              Update All Nodes
            </button>
            <button
              class={[
                "btn",
                if(@cluster_config_mode == :single, do: "btn-primary", else: "btn-outline")
              ]}
              phx-click="set_cluster_mode"
              phx-value-mode="single"
            >
              Update Single Node
            </button>
          </div>

    <!-- Configuration Form -->
          <form phx-submit="update_cluster_config">
            <!-- Single Node Mode: Node Selector -->
            <div :if={@cluster_config_mode == :single} class="form-control mb-4">
              <label class="label">
                <span class="label-text">Select Target Node</span>
              </label>
              <select class="select select-bordered w-full" phx-change="select_node" name="node_id">
                <option value="" selected={@selected_node_id == nil}>
                  Choose a node...
                </option>
                <option
                  :for={node <- @active_nodes}
                  value={node.node_id}
                  selected={@selected_node_id == node.node_id}
                >
                  {node.label}
                </option>
              </select>
            </div>

    <!-- Bootstrap Hosts Input -->
            <div class="form-control mb-4">
              <label class="label">
                <span class="label-text">
                  {if @cluster_config_mode == :all,
                    do: "Bootstrap Hosts for All Nodes",
                    else: "Bootstrap Hosts"}
                </span>
                <span class="label-text-alt">Format: host1:port1, host2:port2</span>
              </label>
              <input
                type="text"
                class="input input-bordered w-full font-mono text-sm"
                value={@cluster_config_input}
                name="bootstrap_hosts"
                placeholder="127.0.0.1:8787, 127.0.0.1:8788"
                phx-change="update_cluster_config_input"
              />
            </div>

    <!-- Update Button -->
            <button
              type="submit"
              class="btn btn-primary"
              disabled={@cluster_config_mode == :single && @selected_node_id == nil}
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-2" />
              {if @cluster_config_mode == :all,
                do: "Update All Nodes",
                else: "Update Selected Node"}
            </button>
          </form>

    <!-- Cluster Readiness Status -->
          <div
            :if={@cluster_readiness_status}
            class={[
              "alert mt-4",
              if(@cluster_readiness_status.ready, do: "alert-success", else: "alert-info")
            ]}
          >
            <.icon
              name={cluster_readiness_icon(@cluster_readiness_status)}
              class={cluster_readiness_icon_class(@cluster_readiness_status)}
            />
            <div>
              <div class="font-semibold">
                {if @cluster_readiness_status.ready do
                  "Cluster Ready"
                else
                  "Waiting for cluster nodes..."
                end}
              </div>
              <div class="text-sm">
                {if @cluster_readiness_status.ready do
                  "All #{@cluster_readiness_status.total} nodes have restarted successfully"
                else
                  "#{@cluster_readiness_status.ready_count}/#{@cluster_readiness_status.total} nodes ready"
                end}
                {if length(@cluster_readiness_status.ready_nodes) > 0 do
                  " (#{Enum.join(@cluster_readiness_status.ready_nodes, ", ")})"
                end}
              </div>
              <div
                :if={length(@cluster_readiness_status.missing_nodes) > 0}
                class="text-xs mt-1 opacity-80"
              >
                Missing: {Enum.join(@cluster_readiness_status.missing_nodes, ", ")}
              </div>
            </div>
          </div>

    <!-- Current Cluster Configs Table -->
          <div :if={length(@cluster_configs) > 0} class="mt-6">
            <h4 class="font-semibold mb-2">Current Node Configurations</h4>
            <div class="overflow-x-auto">
              <table class="table table-zebra table-sm">
                <thead>
                  <tr>
                    <th>Node ID</th>
                    <th>Bootstrap Hosts</th>
                    <th>Last Updated</th>
                    <th>Updated By</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={config <- @cluster_configs}>
                    <td class="font-mono text-xs">{config.node_id}</td>
                    <td class="font-mono text-xs">{config.bootstrap_hosts_display}</td>
                    <td class="text-xs">{config.updated_at}</td>
                    <td class="font-mono text-xs">{config.updated_by}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div :if={length(@cluster_configs) == 0} class="alert alert-warning mt-4">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              No cluster configs found in node_configs table. Use the form above to create initial configs.
            </span>
          </div>
        </div>
      </div>

    <!-- Database Information -->
      <div :if={@db_info} class="card bg-base-100">
        <div class="card-body">
          <h3 class="card-title text-lg">Corrosion Database</h3>
          <div class="space-y-3">
            <div :for={{key, value} <- @db_info} class="text-sm">
              <div class="flex items-start justify-between">
                <span class="font-semibold">{key}:</span>
                <div class="text-right">
                  <div :if={is_list(value)} class="space-y-1">
                    <div :for={item <- value} class="font-mono text-xs">
                      {if is_map(item), do: inspect(item), else: item}
                    </div>
                  </div>
                  <div :if={is_map(value) && Map.has_key?(value, :error)} class="text-error text-xs">
                    Error: {value.error}
                  </div>
                  <div :if={is_map(value) && !Map.has_key?(value, :error)} class="font-mono text-xs">
                    {inspect(value)}
                  </div>
                  <div :if={!is_list(value) && !is_map(value)} class="font-mono text-xs">
                    {inspect(value)}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      <!-- File Information -->
      <div :if={@file_info && !@loading} class="card bg-base-100">
        <div class="card-body">
          <h3 class="card-title text-lg">File System</h3>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>File</th>
                  <th>Status</th>
                  <th>Size</th>
                  <th>Modified</th>
                  <th>Permissions</th>
                  <th>Path</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={file <- @file_info}>
                  <td class="font-semibold">{file.name}</td>
                  <td>
                    <span class={
                      if file.exists,
                        do: "badge badge-success badge-xs",
                        else: "badge badge-error badge-xs"
                    }>
                      {if file.exists, do: "Exists", else: "Missing"}
                    </span>
                  </td>
                  <td class="font-mono text-xs">{file.size}</td>
                  <td class="text-xs">{file.modified}</td>
                  <td class="font-mono text-xs">{file.permissions}</td>
                  <td class="font-mono text-xs text-base-content/70 max-w-xs truncate">
                    {file.path}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

    <!-- Last Updated -->
      <div :if={@last_updated} class="text-xs text-base-content/70 text-center">
        Last updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end

  def connection_indicator(assigns) do
    assigns = assign(assigns, :corro_status, connectivity_status(assigns.api_cx_test))

    ~H"""
    <div class="flex flex-wrap items-center gap-2 rounded-lg bg-base-200 px-3 py-2 text-sm">
      <.icon name={@corro_status.icon} class="h-4 w-4" />
      <span class={"font-semibold " <> @corro_status.class}>{@corro_status.label}</span>
      <span :if={@corro_status.detail} class="text-base-content/70">{@corro_status.detail}</span>
    </div>
    """
  end
end

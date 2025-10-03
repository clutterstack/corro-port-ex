defmodule CorroPortWeb.NodeLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{NodeConfig, ConnectionManager}
  alias CorroPortWeb.NavTabs

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to any relevant updates
      Phoenix.PubSub.subscribe(CorroPort.PubSub, "node_updates")
    end

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
        last_updated: nil
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
    db_info = case CorroClient.get_database_info(conn) do
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

  def connection_indicator(api_cx_test = assigns) do
    assigns = assign( assigns, :corro_status, connectivity_status(assigns.api_cx_test) )
    ~H"""
    <div class="flex flex-wrap items-center gap-2 rounded-lg bg-base-200 px-3 py-2 text-sm">
      <.icon name={@corro_status.icon} class="h-4 w-4" />
      <span class={"font-semibold " <> @corro_status.class}>{@corro_status.label}</span>
      <span :if={@corro_status.detail} class="text-base-content/70">{@corro_status.detail}</span>
    </div>
    """
  end
end

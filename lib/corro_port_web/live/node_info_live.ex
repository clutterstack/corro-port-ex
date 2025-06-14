defmodule CorroPortWeb.NodeInfoLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{NodeConfig, CorrosionClient, ClusterAPI}

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
        corrosion_status: nil,
        process_info: nil,
        file_info: nil,
        error: nil,
        loading: true,
        last_updated: nil
      })

    {:ok, fetch_node_data(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_node_data(socket)}
  end

  def handle_event("test_connection", _params, socket) do
    case CorrosionClient.test_connection() do
      :ok ->
        socket = put_flash(socket, :info, "✅ Connection to Corrosion API successful")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "❌ Connection failed: #{inspect(reason)}")
        {:noreply, socket}
    end
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

  defp fetch_node_data(socket) do
    Logger.info("NodeInfoLive: Fetching comprehensive node data...")

    # Gather all the information
    node_info = get_node_info()
    config_info = get_config_info()
    corrosion_status = get_corrosion_status()
    process_info = get_process_info()
    file_info = get_file_info()

    socket
    |> assign(%{
      node_info: node_info,
      config_info: config_info,
      corrosion_status: corrosion_status,
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
    node_config = NodeConfig.app_node_config() |> dbg
    config_path = NodeConfig.get_config_path() |> dbg

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

  # Simple recursive function to convert keyword lists to maps
  defp keyword_to_map(data) when is_list(data) do
    if Keyword.keyword?(data) do
      Map.new(data, fn {k, v} -> {k, keyword_to_map(v)} end)
    else
      Enum.map(data, &keyword_to_map/1)
    end
  end

  defp keyword_to_map(data), do: data

  defp get_corrosion_status do
    # Test basic connectivity
    connection_status =
      case CorrosionClient.test_connection() do
        :ok -> {:ok, "Connected"}
        {:error, reason} -> {:error, reason}
      end

    # Try to get node info from Corrosion
    local_info =
      case ClusterAPI.get_info() do
        {:ok, info} -> info
        {:error, reason} -> %{error: reason}
      end

    # Try to get cluster members
    cluster_info =
      case ClusterAPI.get_cluster_members() do
        {:ok, members} -> %{member_count: length(members), members: members}
        {:error, reason} -> %{error: reason}
      end

    # Try to get database info
    db_info = ClusterAPI.get_database_info()

    %{
      connection_status: connection_status,
      local_info: local_info,
      cluster_info: cluster_info,
      database_info: db_info
    }
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
    # TODO: get corrosion files from source of truth -- the corrosion config file as
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

  # TODO: add schemas to Corrosion section similarly to how we show the corrosion config TOML file and its contents.
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Node Information
        <:subtitle>
          About this Corrosion node and its configuration
        </:subtitle>
        <:actions>
          <.button phx-click="refresh" variant="primary">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Refresh
          </.button>
          <.button phx-click="test_connection" class="btn btn-secondary">
            <.icon name="hero-signal" class="w-4 h-4 mr-2" /> Test Connection
          </.button>
        </:actions>
      </.header>

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
          </div>

          <div :if={@node_info} class="space-y-3">
            <div class="grid grid-cols-2 gap-4 text-sm">
              <div><strong>Phoenix HTTP:</strong></div>
              <div class="font-mono">
                {@node_info.phoenix_port}
              </div>
            </div>
          </div>
        </div>

        <div :if={@config_info} class="space-y-3">
          <h4 class="font-semibold mb-2">Config from Application Environment:</h4>
          <pre class="bg-base-300 p-4 rounded text-xs overflow-auto">
                <%= Jason.encode!(@config_info.raw_node_config, pretty: true) %>
              </pre>
        </div>

        <div class="card bg-base-100">
          <div class="card-body">
            <div :if={@config_info.config_exists}>
              <h4 class="font-semibold mb-2">Corrosion Config File: {@config_info.config_path}</h4>
              <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= @config_info.config_content %></pre>
            </div>
            <div :if={@config_info.config_exists} class="grid grid-cols-2 gap-2 text-xs">
              <div><strong>Size:</strong> {@config_info.config_size}</div>
              <div><strong>Modified:</strong> {@config_info.config_modified}</div>
              <div></div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Corrosion Status -->
    <div class="card bg-base-100">
      <div class="card-body">
        <h3 class="card-title text-lg">Corrosion Status</h3>
        <div :if={@corrosion_status} class="space-y-3">
          <!-- Connection Status -->
          <div class="flex items-center justify-between">
            <span><strong>API Connection:</strong></span>
            <span class={
              case @corrosion_status.connection_status do
                {:ok, _} -> "badge badge-success"
                {:error, _} -> "badge badge-error"
              end
            }>
              {case @corrosion_status.connection_status do
                {:ok, msg} -> msg
                {:error, reason} -> "Error: #{inspect(reason)}"
              end}
            </span>
          </div>

    <!-- Local Node Active -->
          <div :if={@corrosion_status.local_info} class="space-y-2">
            <div class="flex items-center justify-between">
              <span><strong>Node Active:</strong></span>
              <span class={
                if Map.get(@corrosion_status.local_info, "local_active"),
                  do: "badge badge-success",
                  else: "badge badge-warning"
              }>
                {if Map.get(@corrosion_status.local_info, "local_active"), do: "Yes", else: "No"}
              </span>
            </div>
          </div>

    <!-- Cluster Info -->
          <div
            :if={
              @corrosion_status.cluster_info && !Map.has_key?(@corrosion_status.cluster_info, :error)
            }
            class="space-y-2"
          >
            <div class="flex items-center justify-between">
              <span><strong>Cluster Members:</strong></span>
              <span>{@corrosion_status.cluster_info.member_count}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Process Information -->
    <div class="card bg-base-100">
      <div class="card-body">
        <h3 class="card-title text-lg">Process Information</h3>
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

    <!-- Database Information -->
    <div :if={@corrosion_status && @corrosion_status.database_info} class="card bg-base-100">
      <div class="card-body">
        <h3 class="card-title text-lg">Database Information</h3>
        <div class="space-y-3">
          <div :for={{key, value} <- @corrosion_status.database_info} class="text-sm">
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
                  {value}
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
end

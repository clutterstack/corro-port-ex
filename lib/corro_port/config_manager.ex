defmodule CorroPort.ConfigManager do
  @moduledoc """
  Manages Corrosion configuration file updates and process restarts.

  Production-only module for dynamically updating corrosion.toml and
  restarting the Corrosion agent via Overmind.

  ## Coordinated Restart Mechanism

  This module coordinates with `CorroPort.CorroSubscriber` during Corrosion restarts
  to prevent race conditions and database corruption. The coordination happens via
  PubSub on the `"corrosion_lifecycle"` topic.

  ### Restart Lifecycle

  When `restart_corrosion/0` is called:

  1. **Pre-restart notification** - Broadcasts `{:corrosion_restarting}` to all subscribers
  2. **Grace period** - Waits 500ms for active subscriptions to gracefully close
  3. **Restart execution** - Executes `overmind restart corrosion` command
  4. **Health check** - Polls Corrosion API until responsive (up to 15 attempts @ 1s each)
  5. **Initialization grace** - Additional 3.5s wait for subscription endpoint to stabilise
  6. **Post-restart notification** - Broadcasts `{:corrosion_ready}` to resume subscriptions

  ### Why This Is Necessary

  Without coordination, restarting Corrosion while subscriptions are active causes:
  - **Race conditions**: CorroSubscriber tries to reconnect before Corrosion is ready
  - **Database corruption**: Subscription database creation fails if Corrosion isn't fully initialised
  - **Connection refused errors**: Premature reconnection attempts to unavailable endpoints

  The PubSub coordination ensures subscriptions pause cleanly before restart and only
  resume once Corrosion is fully operational.

  ### PubSub Events

  - `{:corrosion_restarting}` - Broadcast before restart begins (subscribers should pause)
  - `{:corrosion_ready}` - Broadcast after health check + grace period (subscribers can resume)
  """

  require Logger
  alias CorroPort.{NodeConfig, ConnectionManager}

  @corrosion_lifecycle_topic "corrosion_lifecycle"

  @doc """
  Gets the current bootstrap configuration from corrosion.toml.
  Returns a list of host:port strings, or empty list if not set.
  """
  def get_current_bootstrap do
    case read_config_file() do
      {:ok, content} ->
        parse_bootstrap_from_content(content)

      {:error, reason} ->
        Logger.error("Failed to read config file: #{inspect(reason)}")
        {:error, "Could not read config file: #{inspect(reason)}"}
    end
  end

  @doc """
  Updates the bootstrap configuration and optionally restarts Corrosion.

  ## Parameters
  - hosts: List of strings in format "host:port" or comma-separated string
  - restart: Boolean, whether to restart Corrosion after update (default: true)

  ## Returns
  - {:ok, message} on success
  - {:error, reason} on failure
  """
  def update_bootstrap(hosts, restart \\ true) when is_list(hosts) or is_binary(hosts) do
    with :ok <- validate_overmind_available(),
         {:ok, parsed_hosts} <- parse_and_validate_hosts(hosts),
         {:ok, _} <- backup_config(),
         {:ok, _} <- write_new_config(parsed_hosts),
         {:ok, _} <- maybe_restart_corrosion(restart) do
      {:ok, "Bootstrap configuration updated successfully"}
    else
      {:error, reason} = error ->
        Logger.error("Failed to update bootstrap: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Restarts the Corrosion process via Overmind.

  Coordinates with CorroSubscriber via PubSub to ensure graceful restart:
  1. Broadcasts :corrosion_restarting to pause active subscriptions
  2. Restarts Corrosion via overmind
  3. Waits for Corrosion to become responsive
  4. Broadcasts :corrosion_ready to resume subscriptions

  Returns {:ok, output} or {:error, reason}.
  """
  def restart_corrosion do
    with :ok <- validate_overmind_available(),
         :ok <- validate_overmind_running() do
      # Step 1: Notify subscribers to pause
      Logger.info("ConfigManager: Broadcasting :corrosion_restarting")
      Phoenix.PubSub.broadcast(CorroPort.PubSub, @corrosion_lifecycle_topic, {:corrosion_restarting})

      # Give subscribers time to gracefully close
      Process.sleep(500)

      overmind_path = get_overmind_path()
      socket_path = get_overmind_socket_path()

      # Build command args: restart [options] [process]
      args =
        if socket_path do
          ["restart", "-s", socket_path, "corrosion"]
        else
          ["restart", "corrosion"]
        end

      Logger.info("Restarting Corrosion via overmind: #{overmind_path} #{Enum.join(args, " ")}")

      # Step 2: Execute restart
      case System.cmd(overmind_path, args, stderr_to_stdout: true) do
        {output, 0} ->
          Logger.info("Corrosion restart initiated: #{output}")

          # Step 3: Wait for Corrosion to be responsive
          case wait_for_corrosion(15, 1000) do
            {:ok, _msg} ->
              Logger.info("ConfigManager: Corrosion is responsive, adding grace period")
              # Step 4: Grace period for full initialization (subscriptions need extra time)
              Process.sleep(3500)

              # Step 5: Notify subscribers to resume
              Logger.info("ConfigManager: Broadcasting :corrosion_ready")
              Phoenix.PubSub.broadcast(CorroPort.PubSub, @corrosion_lifecycle_topic, {:corrosion_ready})

              {:ok, output}

            {:error, reason} ->
              Logger.error("ConfigManager: Corrosion failed to become responsive: #{inspect(reason)}")
              {:error, "Corrosion restart succeeded but failed health check: #{inspect(reason)}"}
          end

        {output, exit_code} ->
          Logger.error("Overmind restart failed (code #{exit_code}): #{output}")
          {:error, "Restart failed: #{output}"}
      end
    end
  end

  @doc """
  Restores the backup configuration file.
  """
  def rollback_config do
    with :ok <- validate_overmind_available() do
      config_path = NodeConfig.get_config_path()
      backup_path = "#{config_path}.backup"

      if File.exists?(backup_path) do
        case File.cp(backup_path, config_path) do
          :ok ->
            Logger.info("Config rolled back from backup")
            {:ok, "Configuration restored from backup"}

          {:error, reason} ->
            {:error, "Rollback failed: #{inspect(reason)}"}
        end
      else
        {:error, "No backup file found"}
      end
    end
  end

  @doc """
  Waits for Corrosion to become responsive after restart.
  Polls the API for up to max_attempts with delay_ms between attempts.
  """
  def wait_for_corrosion(max_attempts \\ 10, delay_ms \\ 1000) do
    wait_for_corrosion_recursive(max_attempts, delay_ms, 1)
  end

  # Cluster-wide config management functions

  @doc """
  Gets all node configs from the node_configs table.
  Returns {:ok, configs} or {:error, reason}.
  """
  def get_all_node_configs do
    conn = ConnectionManager.get_connection()

    case CorroClient.query(conn, "SELECT * FROM node_configs ORDER BY node_id") do
      {:ok, rows} ->
        configs =
          Enum.map(rows, fn row ->
            parse_node_config_row(row)
          end)

        {:ok, configs}

      {:error, reason} ->
        Logger.error("Failed to query node_configs: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the bootstrap config for a specific node from node_configs table.
  Returns {:ok, config} or {:error, reason}.
  """
  def get_node_config(node_id) do
    conn = ConnectionManager.get_connection()

    query = "SELECT * FROM node_configs WHERE node_id = ? LIMIT 1"

    case CorroClient.query(conn, query, [node_id]) do
      {:ok, [row]} ->
        {:ok, parse_node_config_row(row)}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to query node_config for #{node_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Updates the bootstrap config for a specific node in the node_configs table.
  The change will be gossiped to all nodes, and the target node's ConfigSubscriber
  will apply it automatically.

  ## Parameters
  - node_id: The target node's ID (e.g., "dev-node2")
  - bootstrap_hosts: List of host:port strings or comma-separated string
  """
  def set_node_config(node_id, bootstrap_hosts) when is_list(bootstrap_hosts) or is_binary(bootstrap_hosts) do
    with {:ok, parsed_hosts} <- parse_and_validate_hosts(bootstrap_hosts) do
      conn = ConnectionManager.get_connection()
      local_node_id = NodeConfig.get_corrosion_node_id()
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

      # Convert to JSON array
      hosts_json = Jason.encode!(parsed_hosts)

      # Use UPSERT (INSERT OR REPLACE)
      query = """
      INSERT OR REPLACE INTO node_configs (node_id, bootstrap_hosts, updated_at, updated_by)
      VALUES (?, ?, ?, ?)
      """

      case CorroClient.query(conn, query, [node_id, hosts_json, timestamp, local_node_id]) do
        {:ok, _} ->
          Logger.info("Updated node_configs for #{node_id}: #{hosts_json}")
          {:ok, "Config updated for #{node_id}"}

        {:error, reason} ->
          Logger.error("Failed to update node_configs for #{node_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Updates bootstrap config for all active nodes in the cluster.
  Queries CLIMemberStore for active members and updates each one.

  ## Parameters
  - bootstrap_hosts: List of host:port strings or comma-separated string
  """
  def set_all_node_configs(bootstrap_hosts) do
    with {:ok, parsed_hosts} <- parse_and_validate_hosts(bootstrap_hosts) do
      # Get all active nodes from CLI member store
      active_nodes = get_active_node_ids()

      if Enum.empty?(active_nodes) do
        {:error, "No active nodes found"}
      else
        Logger.info("Updating configs for #{length(active_nodes)} active nodes: #{inspect(active_nodes)}")

        results =
          Enum.map(active_nodes, fn node_id ->
            case set_node_config(node_id, parsed_hosts) do
              {:ok, _} -> {:ok, node_id}
              {:error, reason} -> {:error, {node_id, reason}}
            end
          end)

        errors = Enum.filter(results, &match?({:error, _}, &1))

        if Enum.empty?(errors) do
          {:ok, "Updated configs for #{length(active_nodes)} nodes"}
        else
          {:error, "Some updates failed: #{inspect(errors)}"}
        end
      end
    end
  end

  # Private functions

  defp parse_node_config_row(row) do
    %{
      "node_id" => node_id,
      "bootstrap_hosts" => hosts_json,
      "updated_at" => updated_at,
      "updated_by" => updated_by
    } = row

    # Parse JSON array
    bootstrap_hosts =
      case Jason.decode(hosts_json) do
        {:ok, hosts} when is_list(hosts) -> hosts
        _ -> []
      end

    %{
      node_id: node_id,
      bootstrap_hosts: bootstrap_hosts,
      bootstrap_hosts_display: Enum.join(bootstrap_hosts, ", "),
      updated_at: updated_at,
      updated_by: updated_by
    }
  end

  defp get_active_node_ids do
    # Get active CLI members
    case CorroPort.CLIClusterData.get_members() do
      %{members: {:ok, members}} when is_list(members) ->
        Enum.map(members, fn member ->
          # CLI members have actor_id like "dev-node1", "dev-node2", etc.
          Map.get(member, "actor_id", "unknown")
        end)

      _ ->
        # Fallback: just use local node
        [NodeConfig.get_corrosion_node_id()]
    end
  end

  @doc """
  Checks if this node is running under overmind.
  Returns true if overmind socket file exists (local) or running in production.
  """
  def running_under_overmind? do
    if NodeConfig.production?() do
      true
    else
      # Check if local overmind socket exists
      socket_path = get_overmind_socket_path()
      File.exists?(socket_path)
    end
  end

  defp get_overmind_path do
    # In production (fly.io), overmind is at /app/overmind
    # In development, use absolute path from project root
    if NodeConfig.production?() do
      "/app/overmind"
    else
      project_root = File.cwd!()

      relative_path = case :os.type() do
        {:unix, :darwin} -> "overmind-v2.5.1-macos-arm64"
        {:unix, :linux} -> "overmind-v2.5.1-linux-amd64"
        _ -> "overmind" # Fallback
      end

      Path.join(project_root, relative_path)
    end
  end

  defp get_overmind_socket_path do
    if NodeConfig.production?() do
      # Production doesn't use explicit socket path
      nil
    else
      # Local development: .overmind-node1.sock, .overmind-node2.sock, etc.
      # Extract numeric node ID from "dev-node1" -> "1"
      node_id = NodeConfig.app_node_config()[:node_id] || "1"

      numeric_id =
        case Regex.run(~r/node(\d+)/, node_id) do
          [_, num] -> num
          _ -> node_id  # Fallback to full node_id if no match
        end

      project_root = File.cwd!()
      Path.join(project_root, ".overmind-node#{numeric_id}.sock")
    end
  end

  defp validate_overmind_available do
    if running_under_overmind?() do
      :ok
    else
      {:error, "This operation requires overmind. Start the cluster with ./scripts/overmind-start.sh"}
    end
  end

  defp validate_overmind_running do
    # Check if overmind process is actually running
    case System.cmd("pgrep", ["-f", "overmind"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        {:error, "Overmind is not running"}
    end
  end

  defp read_config_file do
    config_path = NodeConfig.get_config_path()

    case File.read(config_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_bootstrap_from_content(content) do
    # Match bootstrap line: bootstrap = ["host1:port1", "host2:port2"]
    case Regex.run(~r/bootstrap\s*=\s*\[(.*?)\]/s, content) do
      [_, hosts_str] ->
        hosts =
          hosts_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.trim(&1, "\""))
          |> Enum.reject(&(&1 == ""))

        {:ok, hosts}

      nil ->
        {:ok, []}
    end
  end

  defp parse_and_validate_hosts(hosts) when is_binary(hosts) do
    hosts
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> parse_and_validate_hosts()
  end

  defp parse_and_validate_hosts(hosts) when is_list(hosts) do
    validated =
      hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&validate_host_format/1)

    errors = Enum.filter(validated, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      valid_hosts = Enum.map(validated, fn {:ok, host} -> host end)
      {:ok, valid_hosts}
    else
      error_messages = Enum.map(errors, fn {:error, msg} -> msg end)
      {:error, "Invalid hosts: #{Enum.join(error_messages, ", ")}"}
    end
  end

  defp validate_host_format(host) do
    # Basic validation: should be in format "host:port"
    case String.split(host, ":") do
      [hostname, port_str] when hostname != "" and port_str != "" ->
        case Integer.parse(port_str) do
          {port, ""} when port > 0 and port < 65536 ->
            {:ok, host}

          _ ->
            {:error, "Invalid port in #{host}"}
        end

      _ ->
        {:error, "Invalid format for #{host} (expected host:port)"}
    end
  end

  defp backup_config do
    config_path = NodeConfig.get_config_path()
    backup_path = "#{config_path}.backup"

    case File.cp(config_path, backup_path) do
      :ok ->
        Logger.info("Config backed up to #{backup_path}")
        {:ok, backup_path}

      {:error, reason} ->
        {:error, "Backup failed: #{inspect(reason)}"}
    end
  end

  defp write_new_config(bootstrap_hosts) do
    config_path = NodeConfig.get_config_path()
    temp_path = "#{config_path}.tmp"

    # Format bootstrap list for TOML
    bootstrap_list_str =
      bootstrap_hosts
      |> Enum.map(&"\"#{&1}\"")
      |> Enum.join(", ")

    # Generate config based on environment
    config_content =
      if NodeConfig.production?() do
        write_production_config(bootstrap_list_str)
      else
        write_development_config(bootstrap_list_str)
      end

    with :ok <- File.write(temp_path, config_content),
         :ok <- File.rename(temp_path, config_path) do
      Logger.info("New config written with bootstrap: [#{bootstrap_list_str}]")
      {:ok, config_path}
    else
      {:error, reason} ->
        # Clean up temp file if it exists
        File.rm(temp_path)
        {:error, "Failed to write config: #{inspect(reason)}"}
    end
  end

  defp write_production_config(bootstrap_list_str) do
    fly_private_ip = System.get_env("FLY_PRIVATE_IP")
    fly_machine_id = System.get_env("FLY_MACHINE_ID")

    """
    # Generated production config for fly.io machine: #{fly_machine_id}
    [db]
    path = "/opt/data/corrosion/state.db"
    schema_paths = ["/app/schemas"]

    [gossip]
    addr = "[#{fly_private_ip}]:8787"
    bootstrap = [#{bootstrap_list_str}]
    plaintext = true
    max_mtu = 1372
    disable_gso = true

    [api]
    addr = "[::]:8081"

    [admin]
    path = "/app/admin.sock"

    [telemetry]
    prometheus.addr = "0.0.0.0:9090"

    [log]
    colors = false
    """
  end

  defp write_development_config(bootstrap_list_str) do
    node_config = NodeConfig.app_node_config()
    node_id_raw = node_config[:node_id] || "1"
    api_port = node_config[:corrosion_api_port] || 8081
    gossip_port = node_config[:corrosion_gossip_port] || 8787

    # Extract numeric node ID from "dev-node1" -> "1"
    node_id =
      case Regex.run(~r/node(\d+)/, node_id_raw) do
        [_, num] -> num
        _ -> node_id_raw
      end

    """
    # Generated development config for node #{node_id}
    [db]
    path = "corrosion/dev-node#{node_id}.db"
    schema_paths = ["corrosion/schemas"]

    [gossip]
    addr = "127.0.0.1:#{gossip_port}"
    bootstrap = [#{bootstrap_list_str}]
    plaintext = true

    [api]
    addr = "127.0.0.1:#{api_port}"

    [admin]
    path = "/tmp/corrosion/node#{node_id}_admin.sock"
    """
  end

  defp maybe_restart_corrosion(true), do: restart_corrosion()
  defp maybe_restart_corrosion(false), do: {:ok, "Config updated without restart"}

  defp wait_for_corrosion_recursive(0, _delay_ms, attempt) do
    {:error, "Corrosion did not respond after #{attempt - 1} attempts"}
  end

  defp wait_for_corrosion_recursive(attempts_left, delay_ms, attempt) do
    case ConnectionManager.test_connection() do
      :ok ->
        {:ok, "Corrosion is responsive (attempt #{attempt})"}

      _ ->
        Process.sleep(delay_ms)
        wait_for_corrosion_recursive(attempts_left - 1, delay_ms, attempt + 1)
    end
  end
end

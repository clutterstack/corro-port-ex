defmodule CorroPort.ConfigManager do
  @moduledoc """
  Manages Corrosion configuration file updates and process restarts.

  ## Configuration Architecture

  In development, uses a canonical/runtime config split:
  - **Canonical configs**: Known-good baseline configs in `corrosion/configs/canonical/`
  - **Runtime configs**: Active configs in `corrosion/configs/runtime/` (editable via UI)
  - Startup scripts copy canonical → runtime
  - This module edits only runtime configs
  - Fallback: Delete runtime config and restart to restore canonical baseline

  In production, dynamically generates configs based on environment variables.

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
  Restores the canonical configuration file (development only).

  In development, copies the canonical config to runtime config, replacing any edits.
  This provides a quick way to return to the known-good baseline configuration.

  Returns {:ok, message} or {:error, reason}.
  """
  def restore_canonical_config do
    if NodeConfig.production?() do
      {:error, "Canonical config restore is only available in development"}
    else
      runtime_config = NodeConfig.get_config_path()
      canonical_config = get_canonical_config_path()

      cond do
        !File.exists?(canonical_config) ->
          {:error, "No canonical config found at #{canonical_config}"}

        true ->
          case File.cp(canonical_config, runtime_config) do
            :ok ->
              Logger.info("Runtime config restored from canonical: #{canonical_config}")
              {:ok, "Configuration restored from canonical baseline"}

            {:error, reason} ->
              {:error, "Failed to restore canonical config: #{inspect(reason)}"}
          end
      end
    end
  end

  @doc """
  Gets the path to the canonical config file for the current node (development only).
  """
  def get_canonical_config_path do
    if NodeConfig.production?() do
      nil
    else
      node_config = NodeConfig.app_node_config()
      node_id_raw = node_config[:node_id] || "1"

      # Extract numeric node ID from "dev-node1" -> "1"
      node_id =
        case Regex.run(~r/node(\d+)/, node_id_raw) do
          [_, num] -> num
          _ -> node_id_raw
        end

      project_root = File.cwd!()
      Path.join([project_root, "corrosion", "configs", "canonical", "node#{node_id}.toml"])
    end
  end

  @doc """
  Waits for Corrosion to become responsive after restart.
  Polls the API for up to max_attempts with delay_ms between attempts.
  """
  def wait_for_corrosion(max_attempts \\ 10, delay_ms \\ 1000) do
    wait_for_corrosion_recursive(max_attempts, delay_ms, 1)
  end

  @doc """
  Waits for cluster nodes to become ready after a config update.

  Polls CLI members until all expected node_ids appear with connected status.
  Returns {:ok, message} when all nodes are ready, or {:error, status} on timeout.

  ## Parameters
  - expected_node_ids: List of node_ids that should be in the cluster
  - max_attempts: Maximum polling attempts (default: 30)
  - delay_ms: Delay between attempts in milliseconds (default: 2000)

  ## Returns
  - {:ok, message} - All nodes are connected
  - {:error, %{ready: [...], missing: [...], total: N, ready_count: M}} - Timeout with status
  """
  def wait_for_cluster_ready(expected_node_ids, max_attempts \\ 30, delay_ms \\ 2000) do
    wait_for_cluster_recursive(expected_node_ids, max_attempts, delay_ms, 1)
  end

  @doc """
  Checks current cluster readiness status.
  Returns %{ready: boolean, nodes: [...], ready_count: N, total: N}
  """
  def check_cluster_status(expected_node_ids) do
    # Get all node configs to map UUIDs to node_ids
    node_configs = case get_all_node_configs() do
      {:ok, configs} -> configs
      {:error, _} -> []
    end

    uuid_to_node_id = Map.new(node_configs, fn config ->
      {config.corrosion_actor_id, config.node_id}
    end)

    Logger.debug("check_cluster_status: UUID → node_id mapping from node_configs:")
    Enum.each(uuid_to_node_id, fn {uuid, node_id} ->
      Logger.debug("  #{uuid} → #{node_id}")
    end)

    # Get CLI members
    cli_members = case CorroPort.CLIClusterData.get_members() do
      %{members: members} when is_list(members) -> members
      _ -> []
    end

    Logger.debug("check_cluster_status: Found #{length(cli_members)} CLI members")

    # Map CLI members to node_ids with status
    all_member_info = Enum.map(cli_members, fn member ->
      uuid = Map.get(member, "id")
      node_id = Map.get(uuid_to_node_id, uuid)
      status = Map.get(member, "display_status", "unknown")
      %{node_id: node_id, uuid: uuid, status: status}
    end)

    Logger.debug("check_cluster_status: CLI member details: #{inspect(all_member_info)}")
    Logger.debug("check_cluster_status: Expected node_ids: #{inspect(expected_node_ids)}")

    ready_nodes =
      all_member_info
      |> Enum.filter(fn %{node_id: node_id, status: status} ->
        node_id in expected_node_ids && status == "connected"
      end)

    # Always include local node if expected (CLI members doesn't show it)
    local_node_id = NodeConfig.get_corrosion_node_id()
    ready_node_ids = Enum.map(ready_nodes, & &1.node_id)

    Logger.debug("check_cluster_status: Ready nodes from CLI: #{inspect(ready_node_ids)}")
    Logger.debug("check_cluster_status: Local node_id: #{local_node_id}")

    ready_node_ids = if local_node_id in expected_node_ids do
      # Check if local Corrosion is responsive
      local_ready = case ConnectionManager.test_connection() do
        :ok ->
          Logger.debug("check_cluster_status: Local Corrosion is responsive")
          true
        _ ->
          Logger.debug("check_cluster_status: Local Corrosion is NOT responsive")
          false
      end

      if local_ready do
        [local_node_id | ready_node_ids] |> Enum.uniq()
      else
        ready_node_ids
      end
    else
      Logger.debug("check_cluster_status: Local node not in expected list")
      ready_node_ids
    end

    missing_node_ids = expected_node_ids -- ready_node_ids

    Logger.debug("check_cluster_status: Final ready_node_ids: #{inspect(ready_node_ids)}")
    Logger.debug("check_cluster_status: Missing node_ids: #{inspect(missing_node_ids)}")

    %{
      ready: Enum.empty?(missing_node_ids),
      ready_nodes: ready_node_ids,
      missing_nodes: missing_node_ids,
      ready_count: length(ready_node_ids),
      total: length(expected_node_ids)
    }
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

      # Use transaction for write operations with parameterized query
      query = """
      INSERT OR REPLACE INTO node_configs (node_id, bootstrap_hosts, updated_at, updated_by)
      VALUES (?, ?, ?, ?)
      """

      case CorroClient.transaction(conn, [{query, [node_id, hosts_json, timestamp, local_node_id]}]) do
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

        # Write ALL configs in a single transaction to avoid race condition
        # where ConfigSubscriber restarts Corrosion mid-write
        conn = ConnectionManager.get_connection()
        local_node_id = NodeConfig.get_corrosion_node_id()
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        hosts_json = Jason.encode!(parsed_hosts)

        query = """
        INSERT OR REPLACE INTO node_configs (node_id, bootstrap_hosts, updated_at, updated_by)
        VALUES (?, ?, ?, ?)
        """

        # Build list of parameterized queries for transaction
        queries =
          Enum.map(active_nodes, fn node_id ->
            {query, [node_id, hosts_json, timestamp, local_node_id]}
          end)

        case CorroClient.transaction(conn, queries) do
          {:ok, _} ->
            Logger.info("Updated configs for #{length(active_nodes)} nodes in single transaction")
            {:ok, "Updated configs for #{length(active_nodes)} nodes", active_nodes}

          {:error, reason} ->
            Logger.error("Failed to update configs in transaction: #{inspect(reason)}")
            {:error, reason}
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
      corrosion_actor_id: Map.get(row, "corrosion_actor_id"),
      bootstrap_hosts: bootstrap_hosts,
      bootstrap_hosts_display: Enum.join(bootstrap_hosts, ", "),
      updated_at: updated_at,
      updated_by: updated_by
    }
  end

  defp get_active_node_ids do
    # Get all node configs (has UUID -> node_id mapping)
    node_configs = case get_all_node_configs() do
      {:ok, configs} -> configs
      {:error, _} -> []
    end

    # Build UUID -> node_id map
    uuid_to_node_id = Map.new(node_configs, fn config ->
      {config.corrosion_actor_id, config.node_id}
    end)

    Logger.debug("get_active_node_ids: Found #{map_size(uuid_to_node_id)} UUID mappings in node_configs")

    # Get active CLI members (has UUIDs as "id" field)
    case CorroPort.CLIClusterData.get_members() do
      %{members: members} when is_list(members) ->
        Logger.debug("get_active_node_ids: Found #{length(members)} CLI members")

        # Map CLI member UUIDs to node_ids
        mapped_results = Enum.map(members, fn member ->
          uuid = Map.get(member, "id", "unknown")
          node_id = Map.get(uuid_to_node_id, uuid)
          {uuid, node_id}
        end)

        # Log unmapped UUIDs
        unmapped = Enum.filter(mapped_results, fn {_uuid, node_id} -> is_nil(node_id) end)
        if length(unmapped) > 0 do
          Logger.warning("get_active_node_ids: #{length(unmapped)} CLI members not in node_configs: #{inspect(Enum.map(unmapped, fn {uuid, _} -> uuid end))}")
          Logger.warning("These nodes need to run NodeIdentityReporter to register their identity")
        end

        # Extract non-nil node_ids
        node_ids =
          mapped_results
          |> Enum.map(fn {_uuid, node_id} -> node_id end)
          |> Enum.reject(&is_nil/1)

        # Always include local node (CLI members only shows *other* nodes)
        local_node_id = NodeConfig.get_corrosion_node_id()
        all_node_ids = [local_node_id | node_ids] |> Enum.uniq()

        Logger.info("get_active_node_ids: Resolved #{length(all_node_ids)} active node_ids (including local): #{inspect(all_node_ids)}")
        all_node_ids

      _ ->
        Logger.warning("get_active_node_ids: No CLI members found, using local node only")
        # Fallback: just use local node
        [NodeConfig.get_corrosion_node_id()]
    end
  end

  @doc """
  Checks if this node is running under overmind.
  Returns true if overmind process is running for this node or running in production.

  In development, checks both:
  1. Socket file existence (reliable for node 1)
  2. Running overmind process with matching Procfile (fallback for background nodes)
  """
  def running_under_overmind? do
    if NodeConfig.production?() do
      true
    else
      # Check if local overmind socket exists OR overmind process is running
      socket_path = get_overmind_socket_path()
      File.exists?(socket_path) or overmind_process_running?()
    end
  end

  defp overmind_process_running? do
    # Get the expected Procfile name for this node
    node_id = NodeConfig.app_node_config()[:node_id] || "1"

    numeric_id =
      case Regex.run(~r/node(\d+)/, node_id) do
        [_, num] -> num
        _ -> node_id
      end

    procfile_name = "Procfile.node#{numeric_id}-corrosion"

    # Check if overmind is running with this Procfile
    case System.cmd("pgrep", ["-f", "overmind.*#{procfile_name}"], stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        Logger.debug("Found overmind process for #{procfile_name}")
        true

      _ ->
        false
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
      # Production: overmind uses default .overmind.sock in working directory
      "/app/.overmind.sock"
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

  defp wait_for_cluster_recursive(expected_node_ids, 0, _delay_ms, attempt) do
    status = check_cluster_status(expected_node_ids)
    Logger.warning(
      "Cluster readiness timeout after #{attempt - 1} attempts. " <>
      "Ready: #{status.ready_count}/#{status.total} nodes. " <>
      "Missing: #{inspect(status.missing_nodes)}"
    )
    {:error, status}
  end

  defp wait_for_cluster_recursive(expected_node_ids, attempts_left, delay_ms, attempt) do
    status = check_cluster_status(expected_node_ids)

    if status.ready do
      Logger.info(
        "Cluster ready: #{status.ready_count}/#{status.total} nodes connected " <>
        "(attempt #{attempt}). Nodes: #{inspect(status.ready_nodes)}"
      )
      {:ok, "All #{status.total} nodes are ready"}
    else
      Logger.debug(
        "Cluster not ready (#{status.ready_count}/#{status.total}), " <>
        "missing: #{inspect(status.missing_nodes)}, retrying..."
      )
      Process.sleep(delay_ms)
      wait_for_cluster_recursive(expected_node_ids, attempts_left - 1, delay_ms, attempt + 1)
    end
  end
end

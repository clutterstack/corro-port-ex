defmodule CorroPort.NodeConfig do
  @moduledoc """
  Manages node-specific configuration for both Elixir and Corrosion.
  Writes a config file for Corrosion based on application env vars (config values).

  Supports both development (multi-node local testing) and production (fly.io) environments.
  """

  @doc """
  Gets the current node configuration from application config.
  """
  def app_node_config do
    Application.get_env(:corro_port, :node_config)
  end

  @doc """
  Generates a Corrosion TOML configuration file content for the current node.
  Automatically detects development vs production environment.
  """
  def generate_corrosion_config do
    config = app_node_config()
    environment = config[:environment] || :dev

    case environment do
      :prod -> generate_production_config(config)
      _ -> generate_development_config(config)
    end
  end

  @doc """
  Generates production configuration for fly.io deployment.
  """
  def generate_production_config(config) do
    fly_machine_id = config[:fly_machine_id] || config[:node_id]
    api_port = config[:corrosion_api_port]
    gossip_port = config[:corrosion_gossip_port]
    fly_private_ip = config[:fly_private_ip]
    bootstrap_config = config[:corrosion_bootstrap_list]

    # Use machine ID for readability in logs
    node_identifier = fly_machine_id

    """
    # Generated production config for fly.io machine: #{node_identifier}
    [db]
    path = "/var/lib/corrosion/state.db"
    schema_paths = ["/app/corrosion/schemas"]

    [gossip]
    addr = "[#{fly_private_ip}]:#{gossip_port}"
    bootstrap = #{bootstrap_config}
    plaintext = true
    max_mtu = 1372
    disable_gso = true

    [api]
    addr = "[::]:#{api_port}"

    [admin]
    path = "/app/admin.sock"

    [telemetry]
    prometheus.addr = "0.0.0.0:9090"

    [log]
    colors = false
    """
  end

  @doc """
  Generates development configuration for local multi-node testing.
  """
  def generate_development_config(config) do
    node_id = config[:node_id]
    api_port = config[:corrosion_api_port]
    gossip_port = config[:corrosion_gossip_port]
    bootstrap_config = config[:corrosion_bootstrap_list]

    """
    # Generated development config for node #{node_id}
    [db]
    path = "corrosion/node#{node_id}.db"
    schema_paths = ["corrosion/schemas"]

    [gossip]
    addr = "127.0.0.1:#{gossip_port}"
    bootstrap = #{bootstrap_config}
    plaintext = true

    [api]
    addr = "127.0.0.1:#{api_port}"

    [admin]
    path = "/tmp/corrosion/node#{node_id}_admin.sock"
    """
  end

  @doc """
  Writes the Corrosion configuration to a node-specific file.
  """
  def write_corrosion_config do
    config_content = generate_corrosion_config()
    config_path = get_config_path()

    # Ensure the directory exists
    config_dir = Path.dirname(config_path)
    File.mkdir_p!(config_dir)

    # For production, also ensure the admin socket directory exists
    config = app_node_config()
    if config[:environment] == :prod do
      File.mkdir_p!("/app")
    end

    case File.write(config_path, config_content) do
      :ok ->
        {:ok, config_path}

      {:error, reason} ->
        {:error, "Failed to write config file: #{reason}"}
    end
  end

  @doc """
  Gets the path to this node's Corrosion config file.
  """
  def get_config_path do
    config = app_node_config()
    config[:corro_config_path]
  end

  @doc """
  Gets the path to this node's Corrosion binary.
  """
  def get_corro_binary_path do
    config = app_node_config()
    config[:corrosion_binary]
  end

  @doc """
  Gets the Corrosion node identifier (used in logs and for debugging).
  In production, uses the FLY_MACHINE_ID for readability.
  In development, uses the pattern "node#\{id\}".
  """
  def get_corrosion_node_id do
    config = app_node_config()
    environment = config[:environment] || :dev

    case environment do
      :prod ->
        # In production, use the actual machine ID for readability
        config[:fly_machine_id] || config[:node_id] || "unknown"
      _ ->
        # In development, use the familiar nodeN pattern
        "node#{config[:node_id]}"
    end
  end

  @doc """
  Gets the Corrosion API port from the application environment.
  """
  def get_corrosion_api_port do
    config = app_node_config()
    config[:corrosion_api_port]
  end

  @doc """
  Gets the current environment (:dev or :prod).
  """
  def get_environment do
    config = app_node_config()
    config[:environment] || :dev
  end

  @doc """
  Checks if we're running in production (fly.io).
  """
  def production? do
    get_environment() == :prod
  end

  @doc """
  Gets fly.io specific configuration if available.
  Returns nil if not running on fly.io.
  """
  def get_fly_config do
    config = app_node_config()

    if config[:environment] == :prod do
      %{
        app_name: config[:fly_app_name],
        private_ip: config[:fly_private_ip],
        machine_id: config[:fly_machine_id]
      }
    else
      nil
    end
  end
end

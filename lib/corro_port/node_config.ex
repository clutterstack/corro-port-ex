defmodule CorroPort.NodeConfig do
  @moduledoc """
  Manages node-specific configuration for both Elixir and Corrosion.
  Writes a config file for Corrosion based on application env vars (config values).
  """

  @doc """
  Gets the current node configuration from application config.
  """
  def get_node_config do
    Application.get_env(:corro_port, :node_config, %{
      node_id: 1,
      corrosion_api_port: 8081,
      corrosion_gossip_port: 8787,
      ack_port: 5001,
      originating_ip: "127.0.0.1"
    })
  end

  @doc """
  Gets the originating IP for this node.
  In development: 127.0.0.1
  In production: FLY_PRIVATE_IP environment variable
  """
  def get_originating_ip do
    case System.get_env("FLY_PRIVATE_IP") do
      nil ->
        # Development or non-Fly environment
        config = get_node_config()
        config[:originating_ip] || "127.0.0.1"

      fly_ip when is_binary(fly_ip) ->
        # Production on Fly.io
        fly_ip
    end
  end

  @doc """
  Gets the acknowledgment endpoint port for this node.
  """
  def get_ack_port do
    config = get_node_config()
    config[:ack_port] || 5001
  end

  @doc """
  Generates a Corrosion TOML configuration file content for the current node.
  """
  def generate_corrosion_config do
    config = get_node_config()
    node_id = config[:node_id]
    api_port = config[:corrosion_api_port]
    gossip_port = config[:corrosion_gossip_port]

    # For node 1, empty bootstrap list (it becomes the seed)
    # For other nodes, bootstrap from node 1
    bootstrap_config =
      if node_id == 1 do
        "bootstrap = [\"127.0.0.1:8788\"]"
      else
        "bootstrap = [\"127.0.0.1:8787\"]"
      end

    """
    # Generated config for node #{node_id}
    [db]
    path = "corrosion/node#{node_id}.db"
    schema_paths = ["corrosion/schemas"]

    [gossip]
    addr = "127.0.0.1:#{gossip_port}"
    #{bootstrap_config}
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
    config = get_node_config()
    node_id = config[:node_id]

    config_content = generate_corrosion_config()
    config_path = "corrosion/config-node#{node_id}.toml"

    # Ensure the directory exists
    File.mkdir_p!("corrosion")

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
    config = get_node_config()
    node_id = config[:node_id]
    "corrosion/config-node#{node_id}.toml"
  end

  @doc """
  Gets the Corrosion node identifier (used in logs and for debugging).
  """
  def get_corrosion_node_id do
    config = get_node_config()
    "node#{config[:node_id]}"
  end
end

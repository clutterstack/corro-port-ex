defmodule CorroPort.NodeConfig do
  @moduledoc """
  Manages node-specific configuration for both Elixir and Corrosion.
  Writes a config file for Corrosion based on application env vars (config values).
  """

   @doc """
  Gets the current node configuration from application config.
  """
  def app_node_config do
    Application.get_env(:corro_port, :node_config)
  end

  @doc """
  Generates a Corrosion TOML configuration file content for the current node.
  """
  def generate_corrosion_config do
    config = app_node_config()
    node_id = config[:node_id]
    api_port = config[:corrosion_api_port]
    gossip_port = config[:corrosion_gossip_port]
    bootstrap_config = config[:corrosion_bootstrap_list]

    """
    # Generated config for node #{node_id}
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
    config_path = Application.get_env(:corro_port, :node_config)[:corro_config_path]

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
  TODO: get from source of truth
  """
  def get_config_path do
    Application.get_env(:corro_port, :node_config)[:corro_config_path]
  end

  @doc """
  Gets the path to this node's Corrosion binary.
  """
  def get_corro_binary_path do
    Application.get_env(:corro_port, :node_config)[:corrosion_binary]
  end

  @doc """
  Gets the Corrosion node identifier (used in logs and for debugging).
  """
  def get_corrosion_node_id do
    "node#{Application.get_env(:corro_port, :node_config)[:node_id]}"
  end

  @doc """
  Gets the Corrosion api port from the application environment
  """
end

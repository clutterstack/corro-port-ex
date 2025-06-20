defmodule CorroPort.LocalNode do
  @moduledoc """
  Static information about the local node.
  This module provides node identification and configuration details.
  """

  @doc """
  Get comprehensive information about the local node.

  Returns a map with node identification, region, and port configuration.
  """
  def get_info do
    node_config = CorroPort.NodeConfig.app_node_config()

    %{
      node_id: CorroPort.NodeConfig.get_corrosion_node_id(),
      region: CorroPort.RegionExtractor.extract_our_region(),
      environment: CorroPort.NodeConfig.get_environment(),
      ports: %{
        phoenix: get_phoenix_port(),
        api: node_config[:ack_api_port],
        corrosion_api: node_config[:corrosion_api_port],
        corrosion_gossip: node_config[:corrosion_gossip_port]
      },
      config: %{
        fly_app_name: node_config[:fly_app_name],
        fly_region: node_config[:fly_region],
        private_ip: node_config[:private_ip]
      }
    }
  end

  @doc """
  Get just the region for this node.
  """
  def get_region do
    CorroPort.RegionExtractor.extract_our_region()
  end

  @doc """
  Get just the node ID for this node.
  """
  def get_node_id do
    CorroPort.NodeConfig.get_corrosion_node_id()
  end

  defp get_phoenix_port do
    case Application.get_env(:corro_port, CorroPortWeb.Endpoint) do
      nil -> nil
      config -> get_in(config, [:http, :port])
    end
  end
end

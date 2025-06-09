defmodule CorroPort.CorrosionAPI do
  @moduledoc """
  Client for interacting with the Corrosion HTTP API.
  """
  require Logger

  @doc """
  Gets cluster information from the local Corrosion instance.
  Returns {:ok, cluster_info} or {:error, reason}.
  """
  def get_cluster_info(port \\ nil) do
    port = port || get_api_port()
    base_url = "http://127.0.0.1:#{port}"

    Logger.debug("Attempting to connect to Corrosion API at #{base_url}/cluster")

    case Req.get("#{base_url}/cluster") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}
      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}
      {:error, exception} ->
        Logger.warning("Failed to connect to Corrosion API on port #{port}: #{inspect(exception)}")
        {:error, "Connection failed"}
    end
  end

  @doc """
  Gets general information about the local Corrosion instance.
  """
  def get_info(port \\ nil) do
    port = port || get_api_port()
    base_url = "http://127.0.0.1:#{port}"

    Logger.debug("Attempting to connect to Corrosion API at #{base_url}/")

    case Req.get("#{base_url}/") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}
      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}
      {:error, exception} ->
        Logger.warning("Failed to connect to Corrosion API on port #{port}: #{inspect(exception)}")
        {:error, "Connection failed"}
    end
  end

  @doc """
  Determines the Corrosion API port based on the Phoenix port.
  For development, defaults to 8081 as per config-local.toml.
  """
  def get_api_port() do
    # For now, let's use the port from config-local.toml
    # TODO: Make this configurable per node for multi-node setups
    8081
  end

  @doc """
  Try to detect the correct API port by testing common ports.
  """
  def detect_api_port() do
    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000

    # Common port patterns to try
    candidate_ports = [
      8081,  # Default from config
      8082,  # Second node
      8083,  # Third node
      phoenix_port + 4081,  # Calculated offset
    ]

    Logger.debug("Phoenix running on port #{phoenix_port}, trying Corrosion API ports: #{inspect(candidate_ports)}")

    Enum.find(candidate_ports, fn port ->
      case Req.get("http://127.0.0.1:#{port}/", receive_timeout: 1000) do
        {:ok, %{status: 200}} ->
          Logger.info("Found Corrosion API on port #{port}")
          true
        _ ->
          false
      end
    end) || 8081  # Fallback to default
  end
end

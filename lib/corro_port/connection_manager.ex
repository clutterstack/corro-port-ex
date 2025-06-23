defmodule CorroPort.ConnectionManager do
  @moduledoc """
  Centralized connection management for CorroClient connections.
  
  This module provides a unified interface for creating and managing
  connections to the Corrosion database, replacing the previous
  port-based connection system.
  """
  
  require Logger
  
  @doc """
  Get a connection to the local Corrosion node.
  
  Uses the configured API port to create a connection object
  that can be used with the external CorroClient library.
  
  ## Returns
  - Connection object for use with CorroClient functions
  
  ## Examples
      conn = CorroPort.ConnectionManager.get_connection()
      {:ok, results} = CorroClient.query(conn, "SELECT * FROM users")
  """
  def get_connection do
    api_port = get_corro_api_port()
    base_url = "http://127.0.0.1:#{api_port}"
    
    CorroClient.connect(base_url, 
      receive_timeout: 5000,
      headers: [{"content-type", "application/json"}]
    )
  end

  @doc """
  Get a connection optimized for long-running subscriptions.
  
  Uses extended timeouts and keepalive settings suitable for streaming
  connections that may have periods of inactivity.
  
  ## Returns
  - Connection object optimized for subscriptions
  """
  def get_subscription_connection do
    api_port = get_corro_api_port()
    base_url = "http://127.0.0.1:#{api_port}"
    
    CorroClient.connect(base_url,
      receive_timeout: 30_000,  # 30 seconds for subscription setup
      headers: [{"content-type", "application/json"}]
    )
  end
  
  @doc """
  Get a connection to a specific Corrosion node by port.
  
  ## Parameters
  - `port`: The API port of the target node
  
  ## Returns
  - Connection object for use with CorroClient functions
  """
  def get_connection(port) when is_integer(port) do
    base_url = "http://127.0.0.1:#{port}"
    
    CorroClient.connect(base_url,
      receive_timeout: 5000,
      headers: [{"content-type", "application/json"}]
    )
  end
  
  @doc """
  Get the configured Corrosion API port for the current node.
  
  Reads from application config under `:corro_port, :node_config`.
  Falls back to port 8081 if not configured.
  """
  def get_corro_api_port do
    Application.get_env(:corro_port, :node_config)[:corrosion_api_port] || 8081
  end
  
  @doc """
  Test connectivity to the local Corrosion node.
  
  ## Returns
  - `:ok` if connection successful
  - `{:error, reason}` if connection failed
  """
  def test_connection do
    conn = get_connection()
    CorroClient.ping(conn)
  end
  
  @doc """
  Test connectivity to a specific Corrosion node by port.
  
  ## Parameters
  - `port`: The API port to test
  
  ## Returns
  - `:ok` if connection successful
  - `{:error, reason}` if connection failed
  """
  def test_connection(port) when is_integer(port) do
    conn = get_connection(port)
    CorroClient.ping(conn)
  end
end
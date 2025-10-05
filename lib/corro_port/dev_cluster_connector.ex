defmodule CorroPort.DevClusterConnector do
  @moduledoc """
  Automatically connects Elixir nodes in development.

  In dev, nodes are named dev_node1@localhost, dev_node2@localhost, etc.
  This module attempts to connect to all expected peer nodes on startup.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Only run in development
    if Mix.env() == :dev do
      # Give nodes a moment to start, then connect
      Process.send_after(self(), :connect_peers, 2000)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:connect_peers, state) do
    # Try to connect to dev_node1, dev_node2, dev_node3
    # (skip our own node)
    local_node = Node.self()

    peer_nodes = for i <- 1..10 do
      :"dev_node#{i}@#{hostname()}"
    end
    |> Enum.reject(&(&1 == local_node))

    Logger.info("DevClusterConnector: Attempting to connect to peer nodes from #{local_node}...")

    connected = Enum.filter(peer_nodes, fn node ->
      case Node.connect(node) do
        true ->
          Logger.info("DevClusterConnector: ✅ Connected to #{node}")
          true
        false ->
          # Node might not exist yet, that's ok
          false
        :ignored ->
          # Already connected
          Logger.debug("DevClusterConnector: Already connected to #{node}")
          true
      end
    end)

    if length(connected) > 0 do
      Logger.info("DevClusterConnector: Connected to #{length(connected)} peer nodes: #{inspect(connected)}")
      Logger.info("DevClusterConnector: Full cluster: #{inspect([Node.self() | Node.list()])}")
    else
      Logger.info("DevClusterConnector: No peer nodes found (this may be the only node running)")
    end

    # Keep trying to reconnect periodically
    Process.send_after(self(), :connect_peers, 10_000)

    {:noreply, state}
  end

  defp hostname do
    # Get local hostname
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end
end

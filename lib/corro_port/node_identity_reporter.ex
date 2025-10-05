defmodule CorroPort.NodeIdentityReporter do
  @moduledoc """
  Reports this node's Corrosion actor ID to the node_configs table.

  This creates a mapping between:
  - Human-readable node_id (e.g., "dev-node1", "iad-region")
  - Corrosion's internal actor_id (UUID)

  This mapping enables the UI to display friendly labels in dropdowns
  while using the correct UUID for cluster operations.
  """

  use GenServer
  require Logger

  alias CorroPort.{NodeConfig, ConnectionManager}

  @retry_interval 10_000  # Retry every 10 seconds if initial report fails

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the local Corrosion actor ID (UUID).
  """
  def get_local_actor_id do
    GenServer.call(__MODULE__, :get_actor_id, 5000)
  end

  ## Callbacks

  def init(_opts) do
    Logger.info("NodeIdentityReporter: Starting...")

    # Report our identity after a short delay to let Corrosion initialize
    Process.send_after(self(), :report_identity, 2000)

    {:ok, %{actor_id: nil, reported: false}}
  end

  def handle_call(:get_actor_id, _from, state) do
    {:reply, state.actor_id, state}
  end

  def handle_info(:report_identity, state) do
    case report_node_identity() do
      {:ok, actor_id} ->
        Logger.info("NodeIdentityReporter: Successfully reported identity - actor_id: #{actor_id}")
        {:noreply, %{state | actor_id: actor_id, reported: true}}

      {:error, reason} ->
        Logger.warning("NodeIdentityReporter: Failed to report identity: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :report_identity, @retry_interval)
        {:noreply, state}
    end
  end

  ## Private Functions

  defp report_node_identity do
    with {:ok, actor_id} <- fetch_local_actor_id(),
         :ok <- ensure_column_exists(),
         {:ok, _} <- upsert_node_identity(actor_id) do
      {:ok, actor_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_local_actor_id do
    try do
      conn = ConnectionManager.get_connection()

      case CorroClient.query(conn, "SELECT crsql_site_id()", []) do
        {:ok, [result]} ->
          site_id_binary = result["crsql_site_id()"]
          uuid = binary_to_uuid(site_id_binary)
          {:ok, uuid}

        {:error, reason} ->
          {:error, {:query_failed, reason}}
      end
    rescue
      e -> {:error, {:exception, e}}
    end
  end

  defp binary_to_uuid(binary_list) when is_list(binary_list) do
    binary_list
    |> Enum.map(&Integer.to_string(&1, 16) |> String.downcase() |> String.pad_leading(2, "0"))
    |> Enum.join()
    |> format_as_uuid()
  end

  defp format_as_uuid(hex) when byte_size(hex) == 32 do
    String.slice(hex, 0..7) <> "-" <>
    String.slice(hex, 8..11) <> "-" <>
    String.slice(hex, 12..15) <> "-" <>
    String.slice(hex, 16..19) <> "-" <>
    String.slice(hex, 20..31)
  end

  defp ensure_column_exists do
    # The column should exist from schema, but we'll handle the case
    # where it doesn't by attempting to add it (idempotent operation)
    # Note: ALTER TABLE via HTTP API will fail (read-only), so we rely on
    # the schema file having the column defined
    :ok
  end

  defp upsert_node_identity(actor_id) do
    conn = ConnectionManager.get_connection()
    local_node_id = NodeConfig.get_corrosion_node_id()
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # Escape values for SQL (simple approach for strings)
    escaped_node_id = String.replace(local_node_id, "'", "''")
    escaped_actor_id = String.replace(actor_id, "'", "''")
    escaped_timestamp = String.replace(timestamp, "'", "''")

    # Use INSERT OR REPLACE with embedded values (transaction requires literal SQL)
    upsert_statement = """
    INSERT INTO node_configs (node_id, corrosion_actor_id, bootstrap_hosts, updated_at, updated_by)
    VALUES (
      '#{escaped_node_id}',
      '#{escaped_actor_id}',
      COALESCE((SELECT bootstrap_hosts FROM node_configs WHERE node_id = '#{escaped_node_id}'), '[]'),
      '#{escaped_timestamp}',
      '#{escaped_node_id}'
    )
    ON CONFLICT(node_id) DO UPDATE SET
      corrosion_actor_id = excluded.corrosion_actor_id,
      updated_at = excluded.updated_at
    """

    case CorroClient.transaction(conn, [upsert_statement]) do
      {:ok, _} -> {:ok, actor_id}
      {:error, reason} -> {:error, reason}
    end
  end
end

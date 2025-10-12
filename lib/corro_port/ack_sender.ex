defmodule CorroPort.AckSender do
  @moduledoc """
  Sends acknowledgments directly to originating nodes using their endpoint info.

  In production: Uses fly.io 6PN private IPv6 addresses for direct communication
  In development: Uses localhost with different API ports per node

  ## Architecture

  Implemented as a supervised Task (not a GenServer) that:
  - Subscribes to PubSub `message_updates` topic
  - Runs a receive loop to handle incoming messages
  - Spawns background tasks for HTTP acknowledgment sending
  - No state management (purely reactive)

  This design eliminates GenServer overhead for what is essentially a
  message-driven task spawner with no meaningful state to maintain.

  ## Gossip Deduplication and Receipt Tracking

  Messages propagate through the cluster via Corrosion's gossip protocol, which
  means nodes may receive the same message multiple times from different peers.
  This module implements deduplication to ensure only one acknowledgment is sent
  per message.

  **ETS Cache Structure:**
  - Tracks `{message_pk, reception_count, first_seen, last_seen}` for each message
  - `first_seen` timestamp is used as the `receipt_timestamp` in analytics
  - Cache entries expire after 24 hours

  **Behavior:**
  - First reception: Send acknowledgment with `receipt_timestamp` (local clock time)
  - Subsequent receptions: Log duplicate, skip acknowledgment

  **Acknowledgment Payload:**
  ```json
  {
    "message_pk": "node1_1234567890",
    "ack_node_id": "node2",
    "receipt_timestamp": "2025-06-11T10:00:05.123456Z"
  }
  ```

  The `receipt_timestamp` captures when the message first arrived via gossip at
  the acknowledging node's local clock. This enables analysis of message propagation
  patterns without requiring clock synchronisation between nodes.
  """

  require Logger
  alias CorroPort.AckHttp

  @ack_timeout 5_000
  @reception_cache_table :message_reception_cache
  @cache_ttl_hours 24
  # 1 hour
  @cleanup_interval_ms 3_600_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  def run(_opts) do
    Logger.info("AckSender starting...")

    # Create ETS table for message reception tracking and deduplication
    :ets.new(@reception_cache_table, [:set, :public, :named_table, read_concurrency: true])
    Logger.info("AckSender: Created message reception cache table")

    # Subscribe to CorroSubscriber's message updates
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "message_updates")

    # Schedule periodic cleanup of old cache entries
    schedule_cache_cleanup()

    message_loop()
  end

  # Public API for stats/debugging

  def get_status do
    %{status: :running}
  end

  @doc """
  Get reception statistics for a specific message.
  Returns nil if message hasn't been received.
  """
  def get_message_stats(message_pk) do
    case :ets.lookup(@reception_cache_table, message_pk) do
      [{^message_pk, stats}] -> stats
      [] -> nil
    end
  end

  @doc """
  Get all message reception data for heatmap visualization.
  Returns list of %{message_pk, reception_count, first_seen, last_seen}.
  """
  def get_all_reception_stats do
    @reception_cache_table
    |> :ets.tab2list()
    |> Enum.map(fn {message_pk, stats} ->
      Map.put(stats, :message_pk, message_pk)
    end)
    |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})
  end

  @doc """
  Get messages with high gossip redundancy (received multiple times).
  """
  def get_duplicate_receptions(min_count \\ 2) do
    get_all_reception_stats()
    |> Enum.filter(fn stats -> stats.reception_count >= min_count end)
  end

  # Private message handling loop
  defp message_loop do
    receive do
      {:new_message, message_map} ->
        handle_new_message(message_map)
        message_loop()

      {:initial_row, _message_map} ->
        # For initial state, we don't send acks
        message_loop()

      {:message_change, change_type, message_map} ->
        handle_message_change(change_type, message_map)
        message_loop()

      # Ignore other CorroSubscriber events
      {:columns_received, _} ->
        message_loop()

      {:subscription_ready} ->
        message_loop()

      {:subscription_connected, _} ->
        message_loop()

      {:subscription_error, _} ->
        message_loop()

      {:subscription_closed, _} ->
        message_loop()

      :cleanup_cache ->
        cleanup_old_entries()
        schedule_cache_cleanup()
        message_loop()

      msg ->
        Logger.debug("AckSender: Unhandled message: #{inspect(msg)}")
        message_loop()
    end
  end

  defp handle_new_message(message_map) do
    case Map.get(message_map, "node_id") do
      nil ->
        Logger.debug("AckSender: Received message without node_id, skipping")

      originating_node_id ->
        local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

        if originating_node_id != local_node_id do
          start_async_ack(message_map)
        else
          Logger.debug("AckSender: Ignoring message from self (#{local_node_id})")
        end
    end
  end

  defp handle_message_change(change_type, message_map) do
    # Only send acks for INSERTs (new messages), not UPDATEs or DELETEs
    if change_type == "INSERT" do
      originating_node_id = Map.get(message_map, "node_id")
      local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

      if originating_node_id && originating_node_id != local_node_id do
        Logger.info("AckSender: INSERT change from #{originating_node_id}; start ack task")

        start_async_ack(message_map)
      end
    else
      Logger.debug("AckSender: Ignoring #{change_type} change")
    end
  end

  # Private Functions

  defp send_acknowledgment_to_endpoint(message_map) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    originating_endpoint = Map.get(message_map, "originating_endpoint")
    message_pk = Map.get(message_map, "pk")

    if originating_endpoint && message_pk do
      # Check if this is the first time we're receiving this message
      case record_message_reception(message_pk) do
        {:first_reception, receipt_timestamp} ->
          Logger.info("AckSender: First reception of message #{message_pk}")

          case AckHttp.parse_endpoint(originating_endpoint) do
            {:ok, api_url} ->
              send_http_acknowledgment(
                api_url,
                originating_endpoint,
                message_pk,
                receipt_timestamp,
                local_node_id
              )

            {:error, reason} ->
              Logger.warning(
                "AckSender: Could not parse endpoint #{originating_endpoint}: #{reason}"
              )
          end

        {:duplicate, reception_count} ->
          Logger.info(
            "AckSender: Duplicate reception ##{reception_count} of message #{message_pk} (via gossip), skipping acknowledgment"
          )
      end
    else
      Logger.warning(
        "AckSender: Message missing originating_endpoint or pk: #{inspect(message_map)}"
      )
    end
  end

  defp start_async_ack(message_map) do
    case Task.Supervisor.start_child(
           CorroPort.PubSubAckTaskSupervisor,
           fn -> send_acknowledgment_to_endpoint(message_map) end
         ) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("AckSender: failed to start ack task: #{inspect(reason)}")
    end
  end

  defp send_http_acknowledgment(
         api_url,
         originating_endpoint,
         message_pk,
         receipt_timestamp,
         local_node_id
       ) do
    path = "/api/acknowledge"
    ack_url = AckHttp.build_url(api_url, path)

    payload = %{
      "message_pk" => message_pk,
      "ack_node_id" => local_node_id,
      "receipt_timestamp" => DateTime.to_iso8601(receipt_timestamp)
    }

    Logger.info("AckSender: Sending POST to #{ack_url} with payload: #{inspect(payload)}")

    case AckHttp.post_ack(api_url, path, payload, receive_timeout: @ack_timeout) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("AckSender: ✅ Successfully sent acknowledgment to #{originating_endpoint}")
        Logger.debug("AckSender: Response: #{inspect(body)}")

      {:ok, %{status: 404}} ->
        # Target node isn't tracking this message - not an error
        Logger.info(
          "AckSender: Target endpoint #{originating_endpoint} is not tracking message #{message_pk} (404)"
        )

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "AckSender: Acknowledgment failed to #{originating_endpoint}: HTTP #{status}: #{inspect(body)}"
        )

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.warning(
          "AckSender: Acknowledgment timed out to #{originating_endpoint} after #{@ack_timeout}ms"
        )

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        Logger.warning("AckSender: Connection refused to #{originating_endpoint} at #{ack_url}")

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning(
          "AckSender: Acknowledgment failed to #{originating_endpoint}: #{inspect(reason)}"
        )

      {:error, exception} ->
        Logger.warning(
          "AckSender: Acknowledgment failed to #{originating_endpoint}: #{Exception.message(exception)}"
        )
    end
  end

  # Message reception tracking and deduplication

  defp record_message_reception(message_pk) do
    now = DateTime.utc_now()

    case :ets.lookup(@reception_cache_table, message_pk) do
      [] ->
        # First time seeing this message
        stats = %{
          reception_count: 1,
          first_seen: now,
          last_seen: now
        }

        :ets.insert(@reception_cache_table, {message_pk, stats})
        {:first_reception, now}

      [{^message_pk, stats}] ->
        # We've seen this message before - increment counter
        updated_stats = %{
          stats
          | reception_count: stats.reception_count + 1,
            last_seen: now
        }

        :ets.insert(@reception_cache_table, {message_pk, updated_stats})
        {:duplicate, updated_stats.reception_count}
    end
  end

  defp schedule_cache_cleanup do
    Process.send_after(self(), :cleanup_cache, @cleanup_interval_ms)
  end

  defp cleanup_old_entries do
    cutoff_time = DateTime.utc_now() |> DateTime.add(-@cache_ttl_hours, :hour)

    deleted_count =
      @reception_cache_table
      |> :ets.tab2list()
      |> Enum.reduce(0, fn {message_pk, stats}, count ->
        if DateTime.compare(stats.last_seen, cutoff_time) == :lt do
          :ets.delete(@reception_cache_table, message_pk)
          count + 1
        else
          count
        end
      end)

    if deleted_count > 0 do
      Logger.info("AckSender: Cleaned up #{deleted_count} old message reception entries")
    end
  end
end

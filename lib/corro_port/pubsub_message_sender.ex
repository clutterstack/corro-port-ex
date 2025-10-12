defmodule CorroPort.PubSubMessageSender do
  @moduledoc """
  High-level interface for sending messages via Phoenix.PubSub instead of Corrosion.

  This module mirrors the `CorroPort.MessagesAPI` pattern but uses PubSub transport
  instead of the Corrosion database for message propagation. It maintains the same
  acknowledgment tracking and analytics recording behaviour for consistent experiment
  data collection across both transport types.
  """
  require Logger
  alias CorroPort.{PubSubAckTester, AckTracker, AnalyticsStorage, LocalNode}

  @doc """
  Send a message via PubSub and start tracking acknowledgments.

  This mirrors `MessagesAPI.send_and_track_message/2` but uses PubSub transport
  instead of Corrosion gossip. The function:
  - Broadcasts the message via PubSub to all cluster nodes
  - Starts acknowledgment tracking
  - Records analytics if an experiment is active

  ## Parameters
  - `content`: Message content to send
  - `opts`: Options keyword list
    - `:experiment_id` - Optional experiment ID for analytics

  ## Returns
  - `{:ok, message_data}` on success
  - `{:error, reason}` on failure
  """
  def send_and_track_message(content, opts \\ []) do
    local_node_id = LocalNode.get_node_id()

    message_content =
      "#{content} (from #{local_node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()})"

    case PubSubAckTester.send_test_request(message_content) do
      {:ok, request_data} ->
        Logger.info("PubSubMessageSender: Successfully sent message via PubSub: #{inspect(request_data)}")

        # Extract message identifier and timestamp
        message_pk = request_data.request_id
        timestamp_iso = request_data.timestamp

        # Parse the timestamp for analytics
        {:ok, db_timestamp, 0} = DateTime.from_iso8601(timestamp_iso)

        # Record send event in analytics if experiment is active
        record_send_event(
          message_pk,
          local_node_id,
          db_timestamp,
          request_data.region,
          Keyword.get(opts, :experiment_id)
        )

        message_data = %{
          pk: message_pk,
          timestamp: timestamp_iso,
          node_id: local_node_id,
          message: request_data.message,
          transport: :pubsub
        }

        {:ok, message_data}

      {:error, reason} ->
        Logger.warning("PubSubMessageSender: Failed to send message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp record_send_event(message_id, originating_node, timestamp, region, experiment_id_opt) do
    experiment_id =
      experiment_id_opt ||
        AckTracker.get_experiment_id()

    if experiment_id do
      AnalyticsStorage.record_message_event(
        message_id,
        experiment_id,
        originating_node,
        nil,
        :sent,
        timestamp,
        region
      )
    else
      :ok
    end
  end
end

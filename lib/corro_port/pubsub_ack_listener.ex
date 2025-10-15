defmodule CorroPort.PubSubAckListener do
  @moduledoc """
  Listens for PubSub-based acknowledgment test requests and responds by issuing
  HTTP acknowledgments back to the originator node.
  """

  require Logger

  alias CorroPort.{AckHttp, LocalNode}

  @topic "pubsub_ack_test"

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
    Logger.info("PubSubAckListener starting...")
    Phoenix.PubSub.subscribe(CorroPort.PubSub, @topic)
    message_loop()
  end

  defp message_loop do
    receive do
      {:pubsub_ack_request, request_data} ->
        handle_ack_request(request_data)
        message_loop()

      message ->
        Logger.debug("PubSubAckListener: unhandled message #{inspect(message)}")
        message_loop()
    end
  end

  defp handle_ack_request(request_data) when is_map(request_data) do
    local_node_id = LocalNode.get_node_id()
    originating_node_id = fetch(request_data, :originating_node_id)

    if originating_node_id && originating_node_id != local_node_id do
      receipt_timestamp =
        DateTime.utc_now()
        |> DateTime.truncate(:microsecond)

      enriched_request =
        request_data
        |> Map.put_new(:receipt_timestamp, receipt_timestamp)

      Logger.info(
        "PubSubAckListener: received test request #{fetch(request_data, :request_id)} from #{originating_node_id}"
      )

      Task.Supervisor.start_child(
        CorroPort.PubSubAckTaskSupervisor,
        fn -> send_acknowledgment(enriched_request) end
      )
    else
      Logger.debug("PubSubAckListener: ignoring test request from self or missing originator")
    end
  end

  defp handle_ack_request(_other) do
    Logger.debug("PubSubAckListener: received malformed ack request")
  end

  defp send_acknowledgment(request_data) do
    originating_endpoint = fetch(request_data, :originating_endpoint)

    with {:endpoint, true} <- {:endpoint, is_binary(originating_endpoint)},
         {:ok, base_url} <- AckHttp.parse_endpoint(originating_endpoint) do
      receipt_timestamp =
        request_data
        |> fetch(:receipt_timestamp)
        |> normalize_receipt_timestamp()

      payload = %{
        "request_id" => fetch(request_data, :request_id),
        "ack_node_id" => LocalNode.get_node_id(),
        "timestamp" =>
          DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        "receipt_timestamp" =>
          case receipt_timestamp do
            %DateTime{} = dt -> DateTime.to_iso8601(dt)
            _ -> nil
          end
      }

      case AckHttp.post_ack(base_url, "/api/acknowledge_pubsub", payload) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.info(
            "PubSubAckListener: acknowledged request #{payload["request_id"]} to #{originating_endpoint}"
          )

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "PubSubAckListener: ack request #{payload["request_id"]} failed with status #{status}: #{inspect(body)}"
          )

        {:error, %Req.TransportError{reason: reason}} ->
          Logger.warning(
            "PubSubAckListener: ack POST to #{originating_endpoint} failed: #{inspect(reason)}"
          )

        {:error, exception} ->
          Logger.warning(
            "PubSubAckListener: ack POST to #{originating_endpoint} raised: #{Exception.message(exception)}"
          )
      end
    else
      {:endpoint, _} ->
        Logger.warning(
          "PubSubAckListener: missing originating endpoint in #{inspect(request_data)}"
        )

      {:error, reason} ->
        Logger.warning(
          "PubSubAckListener: could not parse endpoint #{inspect(originating_endpoint)}: #{reason}"
        )
    end
  end

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp normalize_receipt_timestamp(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp normalize_receipt_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :microsecond)
      _ -> nil
    end
  end

  defp normalize_receipt_timestamp(_), do: nil
end

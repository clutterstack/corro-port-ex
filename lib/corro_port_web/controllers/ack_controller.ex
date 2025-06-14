defmodule CorroPortWeb.AcknowledgmentController do
  use CorroPortWeb, :controller
  require Logger

  @doc """
  Receives acknowledgment from another node that they've seen our message.

  Expected JSON payload:
  {
    "message_pk": "node1_1234567890",
    "ack_node_id": "node2",
    "message_timestamp": "2025-06-11T10:00:00Z"  // for logging/debugging
  }
  """
  def acknowledge(conn, params) do
    case validate_ack_params(params) do
      {:ok, ack_data} ->
        handle_acknowledgment(conn, ack_data)

      {:error, reason} ->
        Logger.warning(
          "AcknowledgmentController: Invalid acknowledgment request: #{inspect(reason)}"
        )

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid request: #{reason}"})
    end
  end

  defp validate_ack_params(params) do
    required_fields = ["message_pk", "ack_node_id"]

    case check_required_fields(params, required_fields) do
      :ok ->
        {:ok,
         %{
           message_pk: params["message_pk"],
           ack_node_id: params["ack_node_id"],
           # optional, for logging
           message_timestamp: params["message_timestamp"]
         }}

      {:error, missing_fields} ->
        {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp check_required_fields(params, required_fields) do
    missing_fields =
      Enum.filter(required_fields, fn field ->
        is_nil(params[field]) or params[field] == ""
      end)

    case missing_fields do
      [] -> :ok
      missing -> {:error, missing}
    end
  end

  defp handle_acknowledgment(conn, ack_data) do
    Logger.info(
      "AcknowledgmentController: Received acknowledgment from #{ack_data.ack_node_id} for message #{ack_data.message_pk}"
    )

    # Add the acknowledgment to our tracker
    case CorroPort.AckTracker.add_acknowledgment(ack_data.ack_node_id) do
      :ok ->
        Logger.info(
          "AcknowledgmentController: Successfully recorded acknowledgment from #{ack_data.ack_node_id}"
        )

        conn
        |> put_status(:ok)
        |> json(%{
          status: "acknowledged",
          message: "Acknowledgment recorded",
          ack_node_id: ack_data.ack_node_id,
          message_pk: ack_data.message_pk
        })

      {:error, :no_message_tracked} ->
        Logger.warning(
          "AcknowledgmentController: Received acknowledgment for #{ack_data.message_pk} but no message is currently being tracked"
        )

        conn
        |> put_status(:not_found)
        |> json(%{
          error: "No message currently being tracked",
          message_pk: ack_data.message_pk
        })

      {:error, reason} ->
        Logger.error(
          "AcknowledgmentController: Failed to record acknowledgment: #{inspect(reason)}"
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "Failed to record acknowledgment",
          reason: inspect(reason)
        })
    end
  end

  @doc """
  Health check endpoint for acknowledgment API.
  Useful for testing connectivity between nodes.
  """
  def health(conn, _params) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    conn
    |> json(%{
      status: "healthy",
      node_id: local_node_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      ack_tracker_status: CorroPort.AckTracker.get_status()
    })
  end
end

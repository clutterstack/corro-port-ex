defmodule CorroPort.AckTestHelper do
  @moduledoc """
  Helper functions for testing the acknowledgment system.
  """

  require Logger

  @doc """
  Send a test message and monitor for acknowledgments.

      CorroPort.AckTestHelper.send_and_monitor()
  """
  def send_and_monitor do
    IO.puts("🚀 Sending test message and monitoring acknowledgments...")

    # Send a message
    case CorroPortWeb.ClusterLive.MessageHandler.send_message() do
      {:ok, success_message, message_data} ->
        IO.puts("✅ #{success_message}")
        IO.puts("📋 Message data: #{inspect(message_data)}")

        # Wait and check for acknowledgments
        :timer.sleep(2000)

        ack_status = CorroPort.AckTracker.get_status()
        IO.puts("\n🤝 Acknowledgment status after 2 seconds:")
        IO.puts("  Expected: #{ack_status.expected_count}")
        IO.puts("  Received: #{ack_status.ack_count}")

        if ack_status.acknowledgments != [] do
          IO.puts("  From nodes:")
          Enum.each(ack_status.acknowledgments, fn ack ->
            IO.puts("    ✅ #{ack.node_id}")
          end)
        else
          IO.puts("  ❌ No acknowledgments received yet")

          # Let's check what other nodes see
          check_other_nodes_received_message(message_data)
        end

      {:error, error} ->
        IO.puts("❌ Failed to send message: #{error}")
    end
  end

  defp check_other_nodes_received_message(message_data) do
    IO.puts("\n🔍 Checking if other nodes received the message...")

    # Get all messages from database to see if they're replicating
    case CorroPort.MessagesAPI.get_node_messages() do
      {:ok, messages} ->
        # Look for our message
        our_message = Enum.find(messages, fn msg ->
          Map.get(msg, "pk") == message_data.pk
        end)

        if our_message do
          IO.puts("✅ Message found in database")
          IO.puts("   Endpoint: #{Map.get(our_message, "originating_endpoint")}")
        else
          IO.puts("❌ Message not found in database yet")
        end

        # Check total message count by node
        by_node = Enum.group_by(messages, &Map.get(&1, "node_id"))
        IO.puts("\nMessages by node in database:")
        Enum.each(by_node, fn {node_id, node_messages} ->
          IO.puts("  #{node_id}: #{length(node_messages)} messages")
        end)

      {:error, error} ->
        IO.puts("❌ Could not check database: #{inspect(error)}")
    end
  end

  @doc """
  Manually test if a specific endpoint can receive acknowledgments.

      CorroPort.AckTestHelper.test_endpoint_ack("127.0.0.1:5002", "test_message_123")
  """
  def test_endpoint_ack(endpoint, message_pk) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    url = case endpoint do
      "[" <> _ -> "http://#{endpoint}/api/acknowledge"
      _ -> "http://#{endpoint}/api/acknowledge"
    end

    payload = %{
      "message_pk" => message_pk,
      "ack_node_id" => local_node_id,
      "message_timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    IO.puts("Testing acknowledgment to #{endpoint}:")
    IO.puts("  URL: #{url}")
    IO.puts("  Payload: #{inspect(payload)}")

    case Req.post(url,
                  json: payload,
                  headers: [{"content-type", "application/json"}],
                  receive_timeout: 5000) do
      {:ok, %{status: 200, body: body}} ->
        IO.puts("✅ Success: #{inspect(body)}")

      {:ok, %{status: 404}} ->
        IO.puts("⚠️  HTTP 404: Target node not tracking this message")

      {:ok, %{status: status, body: body}} ->
        IO.puts("❌ HTTP #{status}: #{inspect(body)}")

      {:error, %{reason: :econnrefused}} ->
        IO.puts("❌ Connection refused - endpoint not reachable")

      {:error, %{reason: :timeout}} ->
        IO.puts("❌ Timeout - endpoint not responding")

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}")
    end
  end

  @doc """
  Check if CorroSubscriber is receiving message events.

      CorroPort.AckTestHelper.check_subscriber_flow()
  """
  def check_subscriber_flow do
    IO.puts("🔍 Checking CorroSubscriber message flow...")

    # Subscribe to the subscription topic
    Phoenix.PubSub.subscribe(CorroPort.PubSub, CorroPort.CorroSubscriber.subscription_topic())

    IO.puts("📡 Subscribed to CorroSubscriber events")
    IO.puts("💡 Now send a message from another node and watch for events...")
    IO.puts("⏱️  Waiting 30 seconds for events...")

    wait_for_subscriber_events(30)
  end

  defp wait_for_subscriber_events(seconds_left) when seconds_left > 0 do
    receive do
      {:new_message, message_map} ->
        IO.puts("✅ NEW MESSAGE: #{inspect(message_map)}")
        wait_for_subscriber_events(seconds_left - 1)

      {:initial_row, message_map} ->
        IO.puts("📥 INITIAL ROW: #{inspect(message_map)}")
        wait_for_subscriber_events(seconds_left - 1)

      {:message_change, change_type, message_map} ->
        IO.puts("🔄 MESSAGE CHANGE (#{change_type}): #{inspect(message_map)}")
        wait_for_subscriber_events(seconds_left - 1)

      {:columns_received, columns} ->
        IO.puts("📋 COLUMNS: #{inspect(columns)}")
        wait_for_subscriber_events(seconds_left - 1)

      {:subscription_ready} ->
        IO.puts("🎯 SUBSCRIPTION READY")
        wait_for_subscriber_events(seconds_left - 1)

      other ->
        IO.puts("❓ OTHER EVENT: #{inspect(other)}")
        wait_for_subscriber_events(seconds_left - 1)
    after
      1000 ->
        IO.write(".")
        wait_for_subscriber_events(seconds_left - 1)
    end
  end

  defp wait_for_subscriber_events(0) do
    IO.puts("\n⏱️  30 seconds elapsed")
  end

  @doc """
  Force AckSender to process a fake message event.

      CorroPort.AckTestHelper.simulate_message_for_ack_sender()
  """
  def simulate_message_for_ack_sender do
    fake_message = %{
      "pk" => "test_#{System.system_time(:millisecond)}",
      "node_id" => "test_node",
      "message" => "Test message for acknowledgment",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "originating_endpoint" => "127.0.0.1:5999"  # Fake endpoint
    }

    IO.puts("🧪 Simulating message for AckSender:")
    IO.puts("   #{inspect(fake_message)}")

    # Send the event that AckSender would normally receive
    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      CorroPort.CorroSubscriber.subscription_topic(),
      {:new_message, fake_message}
    )

    IO.puts("📡 Event broadcast - check AckSender logs for processing")
  end
end

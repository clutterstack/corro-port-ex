defmodule CorroPort.AckDiagnostics do
  @moduledoc """
  Diagnostic tools for debugging acknowledgment issues.
  """

  require Logger
  alias CorroPort.{MessagesAPI, CorroSubscriber, AckSender, AckTracker, NodeConfig}

  @doc """
  Comprehensive diagnostic check for acknowledgment system.

  Run this in IEx to diagnose acknowledgment issues:

      CorroPort.AckDiagnostics.run_full_diagnostics()
  """
  def run_full_diagnostics do
    IO.puts("\n🔍 Running Acknowledgment System Diagnostics\n")
    IO.puts("=" |> String.duplicate(60))

    # 1. Basic system status
    check_system_status()

    # 2. Message database state
    check_message_database()

    # 3. Subscription system
    check_subscription_system()

    # 4. API connectivity
    check_api_connectivity()

    # 5. Recent message flow
    check_recent_message_flow()

    IO.puts("\n" <> "=" |> String.duplicate(60))
    IO.puts("🏁 Diagnostics Complete\n")
  end

  defp check_system_status do
    IO.puts("📊 System Status")
    IO.puts("-" |> String.duplicate(30))

    local_node_id = NodeConfig.get_corrosion_node_id()
    IO.puts("Local Node ID: #{local_node_id}")

    # Check GenServer statuses
    processes = [
      {"CorroSubscriber", CorroSubscriber},
      {"AckSender", AckSender},
      {"AckTracker", AckTracker}
    ]

    Enum.each(processes, fn {name, module} ->
      status = try do
        if Process.whereis(module) do
          case GenServer.call(module, :status, 1000) do
            %{} = status -> "✅ Running - #{inspect(status)}"
            other -> "⚠️  Unexpected status - #{inspect(other)}"
          end
        else
          "❌ Not running"
        end
      catch
        :exit, _ -> "❌ Not responding"
        error -> "❌ Error: #{inspect(error)}"
      end

      IO.puts("#{name}: #{status}")
    end)

    IO.puts("")
  end

  defp check_message_database do
    IO.puts("💾 Message Database")
    IO.puts("-" |> String.duplicate(30))

    case MessagesAPI.get_node_messages() do
      {:ok, messages} ->
        IO.puts("Total messages in database: #{length(messages)}")

        if messages != [] do
          # Group by node_id
          by_node = Enum.group_by(messages, &Map.get(&1, "node_id"))

          IO.puts("Messages by node:")
          Enum.each(by_node, fn {node_id, node_messages} ->
            latest = Enum.max_by(node_messages, &Map.get(&1, "timestamp", ""))
            endpoint = Map.get(latest, "originating_endpoint", "unknown")
            IO.puts("  #{node_id}: #{length(node_messages)} messages, latest endpoint: #{endpoint}")
          end)

          # Show recent messages
          recent = messages |> Enum.sort_by(&Map.get(&1, "timestamp", ""), :desc) |> Enum.take(3)
          IO.puts("\nRecent messages:")
          Enum.each(recent, fn msg ->
            IO.puts("  #{Map.get(msg, "pk")} | #{Map.get(msg, "node_id")} | #{Map.get(msg, "originating_endpoint")}")
          end)
        end

      {:error, error} ->
        IO.puts("❌ Failed to fetch messages: #{inspect(error)}")
    end

    IO.puts("")
  end

  defp check_subscription_system do
    IO.puts("📡 Subscription System")
    IO.puts("-" |> String.duplicate(30))

    subscriber_status = CorroSubscriber.status()
    IO.puts("CorroSubscriber Status:")
    Enum.each(subscriber_status, fn {key, value} ->
      icon = case {key, value} do
        {:connected, true} -> "✅"
        {:connected, false} -> "❌"
        {:status, :connected} -> "✅"
        {:status, _} -> "⚠️"
        _ -> "ℹ️"
      end
      IO.puts("  #{icon} #{key}: #{inspect(value)}")
    end)

    ack_sender_status = AckSender.get_status()
    IO.puts("\nAckSender Status:")
    Enum.each(ack_sender_status, fn {key, value} ->
      IO.puts("  ℹ️  #{key}: #{value}")
    end)

    IO.puts("")
  end

  defp check_api_connectivity do
    IO.puts("🌐 API Connectivity")
    IO.puts("-" |> String.duplicate(30))

    # Test local API
    local_config = NodeConfig.app_node_config()
    local_api_port = local_config[:api_port]
    local_api_url = "http://127.0.0.1:#{local_api_port}"

    IO.puts("Testing local API endpoint: #{local_api_url}")
    case test_ack_endpoint("#{local_api_url}/api/acknowledge/health") do
      {:ok, response} ->
        IO.puts("✅ Local API responding: #{inspect(response)}")
      {:error, reason} ->
        IO.puts("❌ Local API failed: #{inspect(reason)}")
    end

    # Test endpoints from database
    case MessagesAPI.get_node_messages() do
      {:ok, messages} ->
        endpoints = messages
                   |> Enum.map(&Map.get(&1, "originating_endpoint"))
                   |> Enum.uniq()
                   |> Enum.reject(&is_nil/1)

        if endpoints != [] do
          IO.puts("\nTesting originating endpoints from database:")
          Enum.each(endpoints, fn endpoint ->
            health_url = parse_endpoint_to_health_url(endpoint)
            case test_ack_endpoint(health_url) do
              {:ok, response} ->
                IO.puts("✅ #{endpoint} -> #{health_url}: #{inspect(response)}")
              {:error, reason} ->
                IO.puts("❌ #{endpoint} -> #{health_url}: #{inspect(reason)}")
            end
          end)
        else
          IO.puts("No endpoints found in database messages")
        end

      {:error, _} ->
        IO.puts("Cannot test endpoints - database not accessible")
    end

    IO.puts("")
  end

  defp check_recent_message_flow do
    IO.puts("🔄 Recent Message Flow Analysis")
    IO.puts("-" |> String.duplicate(30))

    # Check AckTracker state
    ack_status = AckTracker.get_status()

    case ack_status do
      %{latest_message: nil} ->
        IO.puts("No message currently being tracked")

      %{latest_message: msg} = status ->
        IO.puts("Currently tracking message:")
        IO.puts("  PK: #{msg.pk}")
        IO.puts("  From: #{msg.node_id}")
        IO.puts("  At: #{msg.timestamp}")
        IO.puts("  Expected acks: #{length(status.expected_nodes)} nodes")
        IO.puts("  Received acks: #{status.ack_count}")

        if status.acknowledgments != [] do
          IO.puts("  Recent acknowledgments:")
          Enum.each(status.acknowledgments, fn ack ->
            IO.puts("    ✅ #{ack.node_id} at #{ack.timestamp}")
          end)
        else
          IO.puts("  ❌ No acknowledgments received yet")
        end

        IO.puts("  Expected from: #{inspect(status.expected_nodes)}")
    end

    IO.puts("")
  end

  # Helper functions

  defp test_ack_endpoint(url) do
    try do
      case Req.get(url, receive_timeout: 3000) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}
        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}
        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error -> {:error, error}
    end
  end

  defp parse_endpoint_to_health_url(endpoint) do
    case endpoint do
      "[" <> rest ->
        # IPv6: [2001:db8::1]:8081 -> http://[2001:db8::1]:8081/api/acknowledge/health
        "http://#{endpoint}/api/acknowledge/health"
      _ ->
        # IPv4: 127.0.0.1:8081 -> http://127.0.0.1:8081/api/acknowledge/health
        "http://#{endpoint}/api/acknowledge/health"
    end
  end

  @doc """
  Test sending a manual acknowledgment to verify the flow.

      CorroPort.AckDiagnostics.test_manual_ack("node1_12345", "node2")
  """
  def test_manual_ack(message_pk, from_node_id) do
    local_config = NodeConfig.app_node_config()
    local_api_port = local_config[:api_port]
    local_api_url = "http://127.0.0.1:#{local_api_port}"

    payload = %{
      "message_pk" => message_pk,
      "ack_node_id" => from_node_id,
      "message_timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    IO.puts("Sending manual acknowledgment:")
    IO.puts("  URL: #{local_api_url}/api/acknowledge")
    IO.puts("  Payload: #{inspect(payload)}")

    case Req.post("#{local_api_url}/api/acknowledge",
                  json: payload,
                  headers: [{"content-type", "application/json"}]) do
      {:ok, %{status: 200, body: body}} ->
        IO.puts("✅ Success: #{inspect(body)}")

      {:ok, %{status: status, body: body}} ->
        IO.puts("❌ Failed: HTTP #{status}: #{inspect(body)}")

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}")
    end
  end

  @doc """
  Monitor acknowledgment flow in real-time.

      CorroPort.AckDiagnostics.monitor_acks()
  """
  def monitor_acks do
    IO.puts("🔍 Monitoring acknowledgment flow... (Press Ctrl+C to stop)")
    IO.puts("Subscribing to PubSub topics...")

    # Subscribe to relevant topics
    Phoenix.PubSub.subscribe(CorroPort.PubSub, CorroPort.CorroSubscriber.subscription_topic())
    Phoenix.PubSub.subscribe(CorroPort.PubSub, CorroPort.AckTracker.get_pubsub_topic())

    monitor_loop()
  end

  defp monitor_loop do
    receive do
      {:new_message, message_map} ->
        IO.puts("📩 New message: #{Map.get(message_map, "pk")} from #{Map.get(message_map, "node_id")}")
        monitor_loop()

      {:ack_update, ack_status} ->
        IO.puts("🤝 Ack update: #{ack_status.ack_count}/#{ack_status.expected_count}")
        monitor_loop()

      other ->
        IO.puts("📡 Other event: #{inspect(other)}")
        monitor_loop()
    after
      30000 ->
        IO.puts("⏱️  30 seconds elapsed, still monitoring...")
        monitor_loop()
    end
  end
end

defmodule CorroPort.DiagnosticTools do
  @moduledoc """
  Tools for diagnosing Corrosion cluster state and replication issues.
  """

  require Logger
  alias CorroPort.CorrosionClient

  @doc """
  Check the replication state across all nodes in the cluster.
  """
  def check_replication_state() do
    Logger.info("=== Corrosion Replication Diagnostics ===")

    # Check basic connectivity
    case CorrosionClient.test_connection() do
      :ok ->
        Logger.info("✅ Corrosion API replied")

      {:error, reason} ->
        Logger.error("❌ Cannot connect to Corrosion API: #{reason}")
        {:error, :no_connection}
    end

    # Check node_messages table state
    check_table_state()

    # Check cluster membership
    check_cluster_membership()

    # Check tracked peers
    check_tracked_peers()

    # Check for replication conflicts
    check_replication_conflicts()

    Logger.info("=== End Diagnostics ===")
  end

  defp check_table_state() do
    Logger.info("--- Checking node_messages table ---")

    case CorrosionClient.execute_query("SELECT COUNT(*) as total FROM node_messages") do
      {:ok, response} ->
        rows = CorrosionClient.parse_query_response(response)
        total = get_in(rows, [Access.at(0), "total"]) || 0
        Logger.info("📊 Total messages: #{total}")

        # Get latest messages per node
        case CorrosionClient.execute_query("""
               SELECT node_id, COUNT(*) as count, MAX(timestamp) as latest_timestamp
               FROM node_messages
               GROUP BY node_id
               ORDER BY latest_timestamp DESC
             """) do
          {:ok, response} ->
            node_stats = CorrosionClient.parse_query_response(response)
            Logger.info("📈 Messages per node:")

            Enum.each(node_stats, fn stat ->
              Logger.info(
                "  #{stat["node_id"]}: #{stat["count"]} messages (latest: #{stat["latest_timestamp"]})"
              )
            end)

          {:error, error} ->
            Logger.warning("⚠️ Could not get per-node stats: #{error}")
        end

      {:error, error} ->
        Logger.warning("⚠️ Could not count messages: #{error}")
    end
  end

  defp check_cluster_membership() do
    Logger.info("--- Checking cluster membership ---")

    case CorrosionClient.execute_query("SELECT * FROM __corro_members") do
      {:ok, response} ->
        members = CorrosionClient.parse_query_response(response)
        Logger.info("👥 Cluster members (#{length(members)}):")

        Enum.each(members, fn member ->
          case Jason.decode(member["foca_state"] || "{}") do
            {:ok, foca_state} ->
              addr = get_in(foca_state, ["id", "addr"]) || "unknown"
              state = foca_state["state"] || "unknown"
              Logger.info("  #{addr}: #{state}")

            {:error, _} ->
              Logger.info("  [parse error]: #{inspect(member)}")
          end
        end)

      {:error, error} ->
        Logger.warning("⚠️ Could not get cluster members: #{error}")
    end
  end

  defp check_tracked_peers() do
    Logger.info("--- Checking tracked peers ---")

    case CorrosionClient.execute_query("SELECT * FROM crsql_tracked_peers") do
      {:ok, response} ->
        peers = CorrosionClient.parse_query_response(response)
        Logger.info("🔗 Tracked peers: #{length(peers)}")

        Enum.each(peers, fn peer ->
          Logger.info("  Peer: #{inspect(peer)}")
        end)

      {:error, error} ->
        Logger.info("ℹ️ No tracked peers table or empty: #{error}")
    end
  end

  defp check_replication_conflicts() do
    Logger.info("--- Checking for replication conflicts ---")
    # TODO: check if there's a way to do this that makes sense.
    # If not, get rid of this check
    # There's probably no need to check for pk conflicts

    # Check if there are duplicate primary keys with different content
    case CorrosionClient.execute_query("""
           SELECT pk, COUNT(*) as count
           FROM node_messages
           GROUP BY pk
           HAVING COUNT(*) > 1
         """) do
      {:ok, response} ->
        conflicts = CorrosionClient.parse_query_response(response)

        if conflicts != [] do
          Logger.warning("⚠️ Found #{length(conflicts)} potential conflicts:")

          Enum.each(conflicts, fn conflict ->
            Logger.warning("  PK '#{conflict["pk"]}' appears #{conflict["count"]} times")
          end)
        else
          Logger.info("✅ No primary key conflicts found")
        end

      {:error, error} ->
        Logger.warning("⚠️ Could not check for conflicts: #{error}")
    end

    # Check for sequence gaps (but sequence is timestamp-based, so this is less meaningful)
    # TODO: just check corro_bookkeeping_gaps table for gaps; current impl doesn't make a lot of sense
    case CorrosionClient.execute_query("""
           SELECT node_id,
                  MIN(sequence) as min_seq,
                  MAX(sequence) as max_seq,
                  COUNT(*) as count,
                  CAST((MAX(sequence) - MIN(sequence)) / 1000.0 AS INTEGER) as time_span_seconds
           FROM node_messages
           GROUP BY node_id
         """) do
      {:ok, response} ->
        node_sequences = CorrosionClient.parse_query_response(response)
        Logger.info("🔢 Sequence analysis (timestamp-based):")

        Enum.each(node_sequences, fn node ->
          count = node["count"] || 0
          time_span = node["time_span_seconds"] || 0

          Logger.info("  #{node["node_id"]}: #{count} messages over #{time_span} seconds")
        end)

      {:error, error} ->
        Logger.warning("⚠️ Could not analyze sequences: #{error}")
    end
  end

  @doc """
  Test message propagation by sending a test message and watching for it on other nodes.
  """
  def test_message_propagation(from_port, to_ports \\ []) when is_list(to_ports) do
    test_message = "PROPAGATION_TEST_#{System.system_time(:millisecond)}"
    test_node = "test_#{System.system_time(:second)}"

    Logger.info("🧪 Testing message propagation...")
    Logger.info("   Sending from port #{from_port} to ports #{inspect(to_ports)}")

    # Send test message
    case CorroPort.MessagesAPI.insert_message(test_node, test_message, from_port) do
      {:ok, _} ->
        Logger.info("✅ Sent test message: #{test_message}")

        # Wait a bit for propagation
        Process.sleep(2000)

        # Check if message appears on other nodes
        results =
          Enum.map([from_port | to_ports], fn port ->
            case CorrosionClient.execute_query(
                   "SELECT * FROM node_messages WHERE message = '#{test_message}'",
                   port
                 ) do
              {:ok, response} ->
                messages = CorrosionClient.parse_query_response(response)
                {port, length(messages) > 0}

              {:error, _} ->
                {port, false}
            end
          end)

        Logger.info("📋 Propagation results:")

        Enum.each(results, fn {port, found} ->
          status = if found, do: "✅", else: "❌"
          Logger.info("   Port #{port}: #{status}")
        end)

        results

      {:error, error} ->
        Logger.error("❌ Failed to send test message: #{error}")
        []
    end
  end

  @doc """
  Quick health check for the current node.
  """
  def health_check() do
    checks = [
      {"API Connection", fn -> CorrosionClient.test_connection() end},
      {"Table Exists",
       fn ->
         case CorrosionClient.execute_query("SELECT 1 FROM node_messages LIMIT 1") do
           {:ok, _} -> :ok
           {:error, _} -> {:error, "Table doesn't exist or is empty"}
         end
       end},
      {"Can Write",
       fn ->
         test_pk = "health_check_#{System.system_time(:millisecond)}"

         case CorrosionClient.execute_transaction([
                "INSERT INTO node_messages (pk, node_id, message, sequence, timestamp) VALUES ('#{test_pk}', 'health', 'test', 0, '2025-01-01T00:00:00Z')"
              ]) do
           {:ok, _} ->
             # Clean up
             CorrosionClient.execute_transaction([
               "DELETE FROM node_messages WHERE pk = '#{test_pk}'"
             ])

             :ok

           error ->
             error
         end
       end}
    ]

    Logger.info("🩺 Health Check for local node:")

    Enum.map(checks, fn {name, check_fn} ->
      case check_fn.() do
        :ok ->
          Logger.info("  ✅ #{name}")
          {name, :ok}

        {:error, reason} ->
          Logger.warning("  ❌ #{name}: #{reason}")
          {name, {:error, reason}}
      end
    end)
  end
end

# Usage examples:
# CorroPort.DiagnosticTools.health_check()
# CorroPort.DiagnosticTools.check_replication_state()
# CorroPort.DiagnosticTools.test_message_propagation(8081, [8082, 8083])

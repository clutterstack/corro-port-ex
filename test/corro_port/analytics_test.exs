defmodule CorroPort.AnalyticsTest do
  use ExUnit.Case, async: true

  alias CorroPort.Analytics
  alias CorroPort.Analytics.{TopologySnapshot, MessageEvent, SystemMetrics}

  setup do
    # Ensure test isolation with sandbox
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CorroPort.Analytics.Repo)

    # Create tables for this test
    Ecto.Adapters.SQL.query!(CorroPort.Analytics.Repo, """
      CREATE TABLE IF NOT EXISTS topology_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        experiment_id TEXT NOT NULL,
        node_id TEXT NOT NULL,
        bootstrap_peers TEXT NOT NULL,
        transaction_size_bytes INTEGER,
        transaction_frequency_ms INTEGER,
        inserted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    """)

    Ecto.Adapters.SQL.query!(CorroPort.Analytics.Repo, """
      CREATE TABLE IF NOT EXISTS message_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id TEXT NOT NULL,
        experiment_id TEXT NOT NULL,
        originating_node TEXT NOT NULL,
        target_node TEXT NOT NULL,
        event_type TEXT NOT NULL,
        region TEXT,
        transaction_size_hint INTEGER,
        inserted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    """)

    Ecto.Adapters.SQL.query!(CorroPort.Analytics.Repo, """
      CREATE TABLE IF NOT EXISTS system_metrics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        experiment_id TEXT NOT NULL,
        node_id TEXT NOT NULL,
        cpu_percent REAL,
        memory_mb INTEGER,
        erlang_processes INTEGER,
        corrosion_connections INTEGER,
        message_queue_length INTEGER,
        inserted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    """)

    :ok
  end

  describe "topology snapshots" do
    test "creates topology snapshot successfully" do
      attrs = %{
        experiment_id: "test_exp_1",
        node_id: "test_node_1",
        bootstrap_peers: ["127.0.0.1:8788", "127.0.0.1:8789"],
        transaction_size_bytes: 1500,
        transaction_frequency_ms: 2000
      }

      assert {:ok, snapshot} = Analytics.create_topology_snapshot(attrs)
      assert snapshot.experiment_id == "test_exp_1"
      assert snapshot.node_id == "test_node_1"
      assert snapshot.bootstrap_peers == ["127.0.0.1:8788", "127.0.0.1:8789"]
      assert snapshot.transaction_size_bytes == 1500
      assert snapshot.transaction_frequency_ms == 2000
    end

    test "validates required fields" do
      attrs = %{experiment_id: "test_exp_1"}
      assert {:error, changeset} = Analytics.create_topology_snapshot(attrs)
      assert changeset.errors[:node_id] != nil
      assert changeset.errors[:bootstrap_peers] != nil
    end

    test "retrieves topology snapshots by experiment" do
      # Create test data
      {:ok, _} =
        Analytics.create_topology_snapshot(%{
          experiment_id: "exp1",
          node_id: "node1",
          bootstrap_peers: ["127.0.0.1:8788"]
        })

      {:ok, _} =
        Analytics.create_topology_snapshot(%{
          experiment_id: "exp2",
          node_id: "node1",
          bootstrap_peers: ["127.0.0.1:8788"]
        })

      snapshots = Analytics.get_topology_snapshots("exp1")
      assert length(snapshots) == 1
      assert hd(snapshots).experiment_id == "exp1"
    end
  end

  describe "message events" do
    test "records message send event" do
      attrs = %{
        message_id: "msg_001",
        experiment_id: "test_exp_1",
        originating_node: "node1",
        target_node: "node2",
        event_type: :sent,
        region: "dev"
      }

      assert {:ok, event} = Analytics.record_message_event(attrs)
      assert event.message_id == "msg_001"
      assert event.event_type == :sent
      assert event.region == "dev"
    end

    test "records message ack event" do
      attrs = %{
        message_id: "msg_001",
        experiment_id: "test_exp_1",
        originating_node: "node1",
        target_node: "node2",
        event_type: :acked
      }

      assert {:ok, event} = Analytics.record_message_event(attrs)
      assert event.event_type == :acked
    end

    test "validates event_type enum" do
      attrs = %{
        message_id: "msg_001",
        experiment_id: "test_exp_1",
        originating_node: "node1",
        target_node: "node2",
        event_type: :invalid_type
      }

      assert {:error, changeset} = Analytics.record_message_event(attrs)
      assert changeset.errors[:event_type] != nil
    end

    test "retrieves message events by experiment" do
      # Create test events
      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg_001",
          experiment_id: "exp1",
          originating_node: "node1",
          target_node: "node2",
          event_type: :sent
        })

      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg_002",
          experiment_id: "exp2",
          originating_node: "node1",
          target_node: "node2",
          event_type: :sent
        })

      events = Analytics.get_message_events("exp1")
      assert length(events) == 1
      assert hd(events).message_id == "msg_001"
    end
  end

  describe "system metrics" do
    test "records system metrics successfully" do
      attrs = %{
        experiment_id: "test_exp_1",
        node_id: "node1",
        cpu_percent: 45.2,
        memory_mb: 512,
        erlang_processes: 150,
        corrosion_connections: 3,
        message_queue_length: 10
      }

      assert {:ok, metrics} = Analytics.record_system_metrics(attrs)
      assert metrics.cpu_percent == 45.2
      assert metrics.memory_mb == 512
      assert metrics.erlang_processes == 150
    end

    test "retrieves system metrics by experiment" do
      # Create test metrics
      {:ok, _} =
        Analytics.record_system_metrics(%{
          experiment_id: "exp1",
          node_id: "node1",
          cpu_percent: 25.0,
          memory_mb: 256,
          erlang_processes: 100
        })

      {:ok, _} =
        Analytics.record_system_metrics(%{
          experiment_id: "exp2",
          node_id: "node1",
          cpu_percent: 30.0,
          memory_mb: 300,
          erlang_processes: 120
        })

      metrics = Analytics.get_system_metrics("exp1")
      assert length(metrics) == 1
      assert hd(metrics).cpu_percent == 25.0
    end
  end

  describe "message timing analysis" do
    test "calculates message latency from send to ack" do
      # Create a send event
      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg_timing_test",
          experiment_id: "timing_exp",
          originating_node: "node1",
          target_node: "node2",
          event_type: :sent
        })

      # Wait a small amount to ensure different timestamps
      :timer.sleep(5)

      # Create an ack event
      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg_timing_test",
          experiment_id: "timing_exp",
          originating_node: "node1",
          target_node: "node2",
          event_type: :acked
        })

      timing_stats = Analytics.get_message_timing_stats("timing_exp")
      assert length(timing_stats) == 1

      stat = hd(timing_stats)
      assert stat.message_id == "msg_timing_test"
      assert stat.min_latency_ms >= 0
      assert stat.send_time != nil
      assert stat.ack_count == 1
    end

    test "handles missing ack events gracefully" do
      # Create only a send event
      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg_no_ack",
          experiment_id: "timing_exp",
          originating_node: "node1",
          target_node: "node2",
          event_type: :sent
        })

      timing_stats = Analytics.get_message_timing_stats("timing_exp")
      assert length(timing_stats) == 1

      stat = hd(timing_stats)
      assert stat.message_id == "msg_no_ack"
      assert stat.min_latency_ms == nil
      assert stat.send_time != nil
      assert stat.ack_count == 0
    end

    test "handles missing send events gracefully" do
      # Create only an ack event (unusual but possible)
      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg_no_send",
          experiment_id: "timing_exp",
          originating_node: "node1",
          target_node: "node2",
          event_type: :acked
        })

      timing_stats = Analytics.get_message_timing_stats("timing_exp")
      # No results expected since timing stats only include messages with send events
      assert length(timing_stats) == 0
    end
  end

  describe "experiment summary" do
    test "provides comprehensive experiment overview" do
      exp_id = "summary_test"

      # Create topology snapshot
      {:ok, _} =
        Analytics.create_topology_snapshot(%{
          experiment_id: exp_id,
          node_id: "node1",
          bootstrap_peers: ["127.0.0.1:8788", "127.0.0.1:8789"]
        })

      # Create message events
      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg1",
          experiment_id: exp_id,
          originating_node: "node1",
          target_node: "node2",
          event_type: :sent
        })

      {:ok, _} =
        Analytics.record_message_event(%{
          message_id: "msg1",
          experiment_id: exp_id,
          originating_node: "node1",
          target_node: "node2",
          event_type: :acked
        })

      # Create system metrics
      {:ok, _} =
        Analytics.record_system_metrics(%{
          experiment_id: exp_id,
          node_id: "node1",
          cpu_percent: 25.0,
          memory_mb: 256,
          erlang_processes: 100
        })

      summary = Analytics.get_experiment_summary(exp_id)

      assert summary.experiment_id == exp_id
      assert summary.topology_snapshots_count == 1
      # One send, one ack
      assert summary.message_count == 2
      assert summary.send_count == 1
      assert summary.ack_count == 1
      assert summary.system_metrics_count == 1
    end
  end
end

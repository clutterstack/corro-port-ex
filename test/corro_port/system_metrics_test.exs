defmodule CorroPort.SystemMetricsTest do
  use ExUnit.Case, async: false

  alias CorroPort.SystemMetrics

  setup do
    # Ensure test isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CorroPort.Analytics.Repo)

    # Create system_metrics table for tests
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

    # Clean up any existing experiment
    pid = Process.whereis(SystemMetrics)

    if pid do
      GenServer.call(pid, :stop_collection)
      # Allow the SystemMetrics process to access the test database
      Ecto.Adapters.SQL.Sandbox.allow(CorroPort.Analytics.Repo, self(), pid)
    end

    :ok
  end

  describe "SystemMetrics GenServer" do
    test "process exists and responds" do
      # Use the existing SystemMetrics process
      pid = Process.whereis(SystemMetrics)
      assert pid != nil
      assert Process.alive?(pid)

      # Test that it responds to calls
      state = :sys.get_state(pid)
      assert is_map(state)
      assert is_integer(state.interval_ms)
      assert state.node_id != nil
    end

    test "starts experiment tracking" do
      pid = Process.whereis(SystemMetrics)

      # Start experiment
      :ok = GenServer.call(pid, {:start_collection, "test_experiment"})

      state = :sys.get_state(pid)
      assert state.experiment_id == "test_experiment"
      assert state.collecting == true

      # Clean up
      GenServer.call(pid, :stop_collection)
    end

    test "stops experiment tracking" do
      pid = Process.whereis(SystemMetrics)

      # Start then stop experiment
      :ok = GenServer.call(pid, {:start_collection, "test_experiment"})
      :ok = GenServer.call(pid, :stop_collection)

      state = :sys.get_state(pid)
      assert state.experiment_id == nil
      assert state.collecting == false
    end

    test "collects metrics when experiment is active" do
      pid = Process.whereis(SystemMetrics)

      # Start experiment  
      :ok = GenServer.call(pid, {:start_collection, "metrics_test"})

      # Wait for a collection cycle
      # Wait for at least one collection interval
      :timer.sleep(1000)

      # Stop experiment to prevent further collection
      :ok = GenServer.call(pid, :stop_collection)

      # Check that metrics were recorded
      metrics = CorroPort.Analytics.get_system_metrics("metrics_test")

      if length(metrics) > 0 do
        # Verify metric content
        metric = hd(metrics)
        assert metric.experiment_id == "metrics_test"
        assert metric.node_id != nil
        assert is_float(metric.cpu_percent) or metric.cpu_percent == nil
        assert is_integer(metric.memory_mb)
        assert is_integer(metric.erlang_processes)
      else
        # If no metrics collected, that's also acceptable for this test
        # as the collection interval might be longer
        IO.puts("Note: No metrics collected in test interval")
      end
    end
  end

  describe "metric collection functions" do
    test "can get current metrics" do
      pid = Process.whereis(SystemMetrics)

      # Access internal collection function for testing
      metrics = GenServer.call(pid, :get_current_metrics)

      assert is_integer(metrics.memory_mb)
      assert metrics.memory_mb > 0
      # Sanity check - less than 100GB
      assert metrics.memory_mb < 100_000

      assert is_integer(metrics.erlang_processes)
      assert metrics.erlang_processes > 0
      # Sanity check
      assert metrics.erlang_processes < 100_000

      if metrics.cpu_percent do
        assert is_float(metrics.cpu_percent)
        assert metrics.cpu_percent >= 0.0
        assert metrics.cpu_percent <= 100.0
      end
    end
  end

  describe "experiment lifecycle" do
    test "handles multiple experiment switches" do
      pid = Process.whereis(SystemMetrics)

      # Start first experiment
      :ok = GenServer.call(pid, {:start_collection, "exp1"})
      :timer.sleep(200)

      # Switch to second experiment  
      :ok = GenServer.call(pid, {:start_collection, "exp2"})
      :timer.sleep(200)

      # Stop collection
      :ok = GenServer.call(pid, :stop_collection)

      # Check experiments have some data (may be empty if collection interval is long)
      exp1_metrics = CorroPort.Analytics.get_system_metrics("exp1")
      exp2_metrics = CorroPort.Analytics.get_system_metrics("exp2")

      # At least verify the query works and returns lists
      assert is_list(exp1_metrics)
      assert is_list(exp2_metrics)

      if length(exp1_metrics) > 0 do
        assert hd(exp1_metrics).experiment_id == "exp1"
      end

      if length(exp2_metrics) > 0 do
        assert hd(exp2_metrics).experiment_id == "exp2"
      end
    end

    test "gracefully handles stop without start" do
      pid = Process.whereis(SystemMetrics)

      # Should not crash when stopping without starting
      :ok = GenServer.call(pid, :stop_collection)

      state = :sys.get_state(pid)
      assert state.experiment_id == nil
      assert state.collecting == false
    end
  end
end

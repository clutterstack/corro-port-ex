defmodule CorroPort.Test.AnalyticsFactory do
  @moduledoc """
  Factory functions for creating test data for analytics tests.

  This module provides functions to create consistent test data
  for topology snapshots, message events, and system metrics.
  """

  alias CorroPort.Analytics

  @doc """
  Creates a topology snapshot with default or provided attributes.
  """
  def create_topology_snapshot(attrs \\ %{}) do
    default_attrs = %{
      experiment_id: "test_experiment_#{:rand.uniform(1000)}",
      node_id: "test_node_#{:rand.uniform(10)}",
      bootstrap_peers: [
        "127.0.0.1:#{8788 + :rand.uniform(5)}",
        "127.0.0.1:#{8788 + :rand.uniform(5)}"
      ],
      transaction_size_bytes: Enum.random([512, 1024, 1500, 2048]),
      transaction_frequency_ms: Enum.random([1000, 2000, 5000])
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, snapshot} = Analytics.create_topology_snapshot(attrs)
    snapshot
  end

  @doc """
  Creates a message event with default or provided attributes.
  """
  def create_message_event(attrs \\ %{}) do
    default_attrs = %{
      message_id: "msg_#{:rand.uniform(100_000)}",
      experiment_id: "test_experiment_#{:rand.uniform(1000)}",
      originating_node: "node_#{:rand.uniform(5)}",
      target_node: "node_#{:rand.uniform(5)}",
      event_type: Enum.random([:sent, :acked]),
      region: Enum.random(["dev", "staging", "prod"])
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, event} = Analytics.record_message_event(attrs)
    event
  end

  @doc """
  Creates a system metrics record with default or provided attributes.
  """
  def create_system_metrics(attrs \\ %{}) do
    default_attrs = %{
      experiment_id: "test_experiment_#{:rand.uniform(1000)}",
      node_id: "test_node_#{:rand.uniform(10)}",
      cpu_percent: :rand.uniform() * 100,
      # 200-1000 MB
      memory_mb: 200 + :rand.uniform(800),
      # 100-300 processes
      erlang_processes: 100 + :rand.uniform(200),
      corrosion_connections: :rand.uniform(10),
      message_queue_length: :rand.uniform(100)
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, metrics} = Analytics.record_system_metrics(attrs)
    metrics
  end

  @doc """
  Creates a complete message flow (send + ack) for timing analysis.
  """
  def create_message_flow(attrs \\ %{}) do
    base_attrs = %{
      message_id: "flow_msg_#{:rand.uniform(100_000)}",
      experiment_id: "test_experiment_#{:rand.uniform(1000)}",
      originating_node: "node_1",
      target_node: "node_2",
      region: "test"
    }

    final_attrs = Map.merge(base_attrs, attrs)

    # Create send event
    send_attrs = Map.put(final_attrs, :event_type, :sent)
    {:ok, send_event} = Analytics.record_message_event(send_attrs)

    # Small delay to ensure different timestamps
    :timer.sleep(1)

    # Create ack event
    ack_attrs = Map.put(final_attrs, :event_type, :acked)
    {:ok, ack_event} = Analytics.record_message_event(ack_attrs)

    {send_event, ack_event}
  end

  @doc """
  Creates a complete experiment setup with topology, messages, and metrics.
  """
  def create_complete_experiment(experiment_id \\ nil) do
    experiment_id = experiment_id || "complete_exp_#{:rand.uniform(1000)}"

    # Create topology snapshot
    topology = create_topology_snapshot(%{experiment_id: experiment_id})

    # Create several message flows
    message_flows =
      Enum.map(1..3, fn _ ->
        create_message_flow(%{experiment_id: experiment_id})
      end)

    # Create some incomplete messages (sent but not acked)
    incomplete_messages =
      Enum.map(1..2, fn _ ->
        create_message_event(%{
          experiment_id: experiment_id,
          event_type: :sent
        })
      end)

    # Create system metrics
    metrics =
      Enum.map(1..5, fn _ ->
        create_system_metrics(%{experiment_id: experiment_id})
      end)

    %{
      experiment_id: experiment_id,
      topology: topology,
      complete_flows: message_flows,
      incomplete_messages: incomplete_messages,
      metrics: metrics
    }
  end

  @doc """
  Creates test data for multi-node experiment scenarios.
  """
  def create_multi_node_experiment(node_count \\ 3) do
    experiment_id = "multi_node_exp_#{:rand.uniform(1000)}"

    # Create topology snapshots for each node
    topologies =
      Enum.map(1..node_count, fn node_num ->
        create_topology_snapshot(%{
          experiment_id: experiment_id,
          node_id: "node_#{node_num}"
        })
      end)

    # Create cross-node message flows
    message_flows =
      for from_node <- 1..node_count,
          to_node <- 1..node_count,
          from_node != to_node do
        create_message_flow(%{
          experiment_id: experiment_id,
          originating_node: "node_#{from_node}",
          target_node: "node_#{to_node}"
        })
      end

    # Create metrics for each node
    metrics =
      Enum.flat_map(1..node_count, fn node_num ->
        Enum.map(1..3, fn _ ->
          create_system_metrics(%{
            experiment_id: experiment_id,
            node_id: "node_#{node_num}"
          })
        end)
      end)

    %{
      experiment_id: experiment_id,
      node_count: node_count,
      topologies: topologies,
      message_flows: message_flows,
      metrics: metrics
    }
  end

  @doc """
  Creates test data for performance analysis scenarios.
  """
  def create_performance_test_data(message_count \\ 100) do
    experiment_id = "perf_test_#{:rand.uniform(1000)}"

    # Create baseline topology
    topology =
      create_topology_snapshot(%{
        experiment_id: experiment_id,
        transaction_size_bytes: 1024,
        # High frequency
        transaction_frequency_ms: 100
      })

    # Create many message flows with varying delays
    message_flows =
      Enum.map(1..message_count, fn i ->
        # Introduce some artificial delay variation
        delay = :rand.uniform(50)

        # Create send event
        {:ok, send_event} =
          Analytics.record_message_event(%{
            message_id: "perf_msg_#{i}",
            experiment_id: experiment_id,
            originating_node: "perf_node_1",
            target_node: "perf_node_2",
            event_type: :sent
          })

        # Variable delay before ack
        :timer.sleep(delay)

        # Create ack event
        {:ok, ack_event} =
          Analytics.record_message_event(%{
            message_id: "perf_msg_#{i}",
            experiment_id: experiment_id,
            originating_node: "perf_node_1",
            target_node: "perf_node_2",
            event_type: :acked
          })

        {send_event, ack_event}
      end)

    # Create corresponding system metrics showing load
    metrics =
      Enum.map(1..10, fn i ->
        # Simulate increasing load over time
        cpu_load = min(10.0 + i * 5.0, 95.0)
        memory_usage = 300 + i * 20

        create_system_metrics(%{
          experiment_id: experiment_id,
          cpu_percent: cpu_load,
          memory_mb: memory_usage,
          erlang_processes: 150 + i * 5
        })
      end)

    %{
      experiment_id: experiment_id,
      message_count: message_count,
      topology: topology,
      message_flows: message_flows,
      metrics: metrics
    }
  end
end

# scripts/tidewave-analytics.exs
# Enhanced Tidewave integration for CorroPort analytics
# 
# This script leverages Tidewave to provide better debugging and monitoring
# of the analytics flow. Place this in your Tidewave configuration or run
# directly for enhanced observability.

# Configure Tidewave for analytics debugging
if Code.ensure_loaded?(Tidewave) do
  alias CorroPort.{AnalyticsAggregator, MessagePropagation, Analytics}
  
  # Add analytics-specific watchers
  Tidewave.watch(CorroPort.AnalyticsAggregator, [
    :start_experiment_aggregation,
    :stop_experiment_aggregation,
    :get_cluster_experiment_summary,
    :get_cluster_timing_stats,
    :get_active_nodes
  ])
  
  Tidewave.watch(CorroPort.MessagePropagation, [
    :send_message,
    :get_ack_data,
    :set_experiment_id
  ])
  
  Tidewave.watch(CorroPort.Analytics, [
    :get_experiment_summary,
    :get_message_timing_stats,
    :get_system_metrics
  ])
  
  # Add process watchers for key analytics processes
  Tidewave.watch_process(CorroPort.AnalyticsAggregator)
  Tidewave.watch_process(CorroPort.SystemMetrics)
  Tidewave.watch_process(CorroPort.MessagePropagation)
  
  # Custom analytics commands for Tidewave
  defmodule CorroPort.TidewaveCommands do
    @moduledoc """
    Custom Tidewave commands for CorroPort analytics debugging.
    
    Available commands:
    - analytics.start_demo(experiment_id)
    - analytics.send_test_messages(count)
    - analytics.get_status()
    - analytics.show_cluster_health()
    """
    
    def start_demo(experiment_id \\ "tidewave_demo_#{System.system_time(:second)}") do
      IO.puts("🚀 Starting analytics demo with experiment: #{experiment_id}")
      
      # Start aggregation
      case AnalyticsAggregator.start_experiment_aggregation(experiment_id) do
        :ok -> 
          IO.puts("✅ Aggregation started")
          
          # Show active nodes
          nodes = AnalyticsAggregator.get_active_nodes()
          IO.puts("📡 Found #{length(nodes)} active nodes:")
          Enum.each(nodes, fn node ->
            IO.puts("  - #{node.node_id} (#{node.region})")
          end)
          
          experiment_id
          
        error ->
          IO.puts("❌ Failed to start aggregation: #{inspect(error)}")
          nil
      end
    end
    
    def send_test_messages(count \\ 3) do
      IO.puts("📤 Sending #{count} test messages...")
      
      for i <- 1..count do
        content = "Tidewave test message ##{i} - #{DateTime.utc_now() |> DateTime.to_iso8601()}"
        
        case MessagePropagation.send_message(content) do
          {:ok, message_data} ->
            IO.puts("✅ Message #{i} sent: #{message_data.pk}")
            
          {:error, reason} ->
            IO.puts("❌ Message #{i} failed: #{inspect(reason)}")
        end
        
        Process.sleep(1000)
      end
      
      IO.puts("📤 All messages sent")
    end
    
    def get_status() do
      IO.puts("📊 Analytics System Status")
      IO.puts("=" <> String.duplicate("=", 25))
      
      # Active nodes
      nodes = AnalyticsAggregator.get_active_nodes()
      IO.puts("Active Nodes: #{length(nodes)}")
      Enum.each(nodes, fn node ->
        status = if node.is_local, do: "LOCAL", else: "REMOTE"
        IO.puts("  - #{node.node_id} (#{node.region}) [#{status}]")
      end)
      
      # Current experiment
      experiment_id = MessagePropagation.get_experiment_id()
      IO.puts("Current Experiment: #{experiment_id || "None"}")
      
      # Process status
      processes = [
        {AnalyticsAggregator, "Analytics Aggregator"},
        {MessagePropagation, "Message Propagation"},
        {CorroPort.SystemMetrics, "System Metrics"}
      ]
      
      IO.puts("Process Status:")
      Enum.each(processes, fn {module, name} ->
        case Process.whereis(module) do
          nil -> IO.puts("  - #{name}: ❌ Not Running")
          pid -> IO.puts("  - #{name}: ✅ Running (#{inspect(pid)})")
        end
      end)
    end
    
    def show_cluster_health() do
      IO.puts("🏥 Cluster Health Check")
      IO.puts("=" <> String.duplicate("=", 22))
      
      # Check each node's health
      nodes = AnalyticsAggregator.get_active_nodes()
      
      for node <- nodes do
        port = node.phoenix_port || 4001
        url = "http://localhost:#{port}/api/analytics/health"
        
        IO.write("Node #{node.node_id}: ")
        
        case make_health_request(url) do
          {:ok, %{"status" => "ok"}} ->
            IO.puts("✅ Healthy")
            
          {:ok, response} ->
            IO.puts("⚠️  Partial: #{inspect(response)}")
            
          {:error, reason} ->
            IO.puts("❌ Failed: #{inspect(reason)}")
        end
      end
    end
    
    defp make_health_request(url) do
      case Req.get(url, receive_timeout: 2000, retry: false) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
        {:error, reason} -> {:error, reason}
      end
    end
  end
  
  # Register commands
  Tidewave.add_commands(CorroPort.TidewaveCommands, prefix: "analytics")
  
  IO.puts("""
  
  🌊 Tidewave Analytics Integration Loaded!
  
  Try these commands:
    analytics.start_demo()
    analytics.send_test_messages(5)
    analytics.get_status()
    analytics.show_cluster_health()
  
  Happy debugging! 🐛✨
  """)
  
else
  IO.puts("⚠️  Tidewave not available. Install with: {:tidewave, \"~> 0.1\", only: :dev}")
end
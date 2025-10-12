defmodule CorroPortWeb.AnalyticsApiController do
  @moduledoc """
  HTTP API endpoints for analytics data retrieval.

  These endpoints are called by the AnalyticsAggregator to collect
  data from remote nodes in the cluster during experiments.

  All endpoints return JSON data and include CORS headers to support
  cross-origin requests within the cluster.
  """

  use CorroPortWeb, :controller

  alias CorroPort.Analytics
  alias CorroPort.Analytics.Queries

  @doc """
  GET /api/analytics/experiments/:experiment_id/summary

  Returns experiment summary with counts of different data types.
  """
  def experiment_summary(conn, %{"experiment_id" => experiment_id}) do
    try do
      summary = Analytics.get_experiment_summary(experiment_id)

      json(conn, %{
        experiment_id: summary.experiment_id,
        topology_snapshots_count: summary.topology_snapshots_count,
        message_count: summary.message_count,
        send_count: summary.send_count,
        ack_count: summary.ack_count,
        system_metrics_count: summary.system_metrics_count,
        node_id: CorroPort.LocalNode.get_node_id(),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get experiment summary: #{inspect(error)}"})
    end
  end

  @doc """
  GET /api/analytics/experiments/:experiment_id/timing

  Returns message timing statistics for all messages in the experiment.
  """
  def timing_stats(conn, %{"experiment_id" => experiment_id}) do
    try do
      timing_stats = Queries.get_message_timing_stats(experiment_id)

      # Convert to JSON-friendly format
      stats_json =
        Enum.map(timing_stats, fn stat ->
          %{
            message_id: stat.message_id,
            send_time: format_datetime(stat.send_time),
            ack_count: stat.ack_count,
            min_latency_ms: stat.min_latency_ms,
            max_latency_ms: stat.max_latency_ms,
            avg_latency_ms: stat.avg_latency_ms
          }
        end)

      json(conn, %{
        experiment_id: experiment_id,
        node_id: CorroPort.LocalNode.get_node_id(),
        timing_stats: stats_json,
        count: length(stats_json),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get timing stats: #{inspect(error)}"})
    end
  end

  @doc """
  GET /api/analytics/experiments/:experiment_id/metrics

  Returns system metrics collected during the experiment.
  """
  def system_metrics(conn, %{"experiment_id" => experiment_id}) do
    try do
      metrics = Analytics.get_system_metrics(experiment_id)

      # Convert to JSON-friendly format
      metrics_json =
        Enum.map(metrics, fn metric ->
          %{
            id: metric.id,
            experiment_id: metric.experiment_id,
            node_id: metric.node_id,
            cpu_percent: metric.cpu_percent,
            memory_mb: metric.memory_mb,
            erlang_processes: metric.erlang_processes,
            corrosion_connections: metric.corrosion_connections,
            message_queue_length: metric.message_queue_length,
            inserted_at: format_datetime(metric.inserted_at)
          }
        end)

      json(conn, %{
        experiment_id: experiment_id,
        node_id: CorroPort.LocalNode.get_node_id(),
        system_metrics: metrics_json,
        count: length(metrics_json),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get system metrics: #{inspect(error)}"})
    end
  end

  @doc """
  GET /api/analytics/experiments/:experiment_id/events

  Returns all message events (send/ack) for the experiment.
  """
  def message_events(conn, %{"experiment_id" => experiment_id}) do
    try do
      events = Analytics.get_message_events(experiment_id)

      # Convert to JSON-friendly format
      events_json =
        Enum.map(events, fn event ->
          %{
            id: event.id,
            message_id: event.message_id,
            experiment_id: event.experiment_id,
            originating_node: event.originating_node,
            target_node: event.target_node,
            event_type: event.event_type,
            region: event.region,
            transaction_size_hint: event.transaction_size_hint,
            inserted_at: format_datetime(event.inserted_at)
          }
        end)

      json(conn, %{
        experiment_id: experiment_id,
        node_id: CorroPort.LocalNode.get_node_id(),
        message_events: events_json,
        count: length(events_json),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get message events: #{inspect(error)}"})
    end
  end

  @doc """
  GET /api/analytics/experiments/:experiment_id/topology

  Returns topology snapshots for the experiment.
  """
  def topology_snapshots(conn, %{"experiment_id" => experiment_id}) do
    try do
      snapshots = Analytics.get_topology_snapshots(experiment_id)

      # Convert to JSON-friendly format
      snapshots_json =
        Enum.map(snapshots, fn snapshot ->
          %{
            id: snapshot.id,
            experiment_id: snapshot.experiment_id,
            node_id: snapshot.node_id,
            bootstrap_peers: snapshot.bootstrap_peers,
            transaction_size_bytes: snapshot.transaction_size_bytes,
            transaction_frequency_ms: snapshot.transaction_frequency_ms,
            inserted_at: format_datetime(snapshot.inserted_at),
            updated_at: format_datetime(snapshot.updated_at)
          }
        end)

      json(conn, %{
        experiment_id: experiment_id,
        node_id: CorroPort.LocalNode.get_node_id(),
        topology_snapshots: snapshots_json,
        count: length(snapshots_json),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get topology snapshots: #{inspect(error)}"})
    end
  end

  @doc """
  POST /api/analytics/aggregation/start

  Start analytics aggregation for an experiment.
  """
  def start_aggregation(conn, %{"experiment_id" => experiment_id}) do
    try do
      result = CorroPort.AnalyticsAggregator.start_experiment_aggregation(experiment_id)

      json(conn, %{
        status: "success",
        result: result,
        experiment_id: experiment_id,
        node_id: CorroPort.LocalNode.get_node_id(),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          error: "Failed to start aggregation: #{inspect(error)}",
          timestamp: DateTime.utc_now()
        })
    end
  end

  @doc """
  POST /api/analytics/aggregation/stop

  Stop analytics aggregation.
  """
  def stop_aggregation(conn, _params) do
    try do
      result = CorroPort.AnalyticsAggregator.stop_experiment_aggregation()

      json(conn, %{
        status: "success",
        result: result,
        node_id: CorroPort.LocalNode.get_node_id(),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          error: "Failed to stop aggregation: #{inspect(error)}",
          timestamp: DateTime.utc_now()
        })
    end
  end

  @doc """
  POST /api/messages/send

  Send a test message for analytics tracking.
  """
  def send_message(conn, %{"content" => content}) do
    try do
      case CorroPort.MessagesAPI.send_and_track_message(content) do
        {:ok, message_data} ->
          json(conn, %{
            status: "success",
            message: %{
              pk: message_data.pk,
              timestamp: format_datetime(message_data.timestamp),
              node_id: message_data.node_id,
              sequence: message_data.sequence
            },
            node_id: CorroPort.LocalNode.get_node_id(),
            timestamp: DateTime.utc_now()
          })

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{
            status: "error",
            error: "Failed to send message: #{inspect(reason)}",
            timestamp: DateTime.utc_now()
          })
      end
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          error: "Exception sending message: #{inspect(error)}",
          timestamp: DateTime.utc_now()
        })
    end
  end

  @doc """
  GET /api/analytics/aggregation/status

  Get the current aggregation status and active nodes.
  """
  def aggregation_status(conn, _params) do
    try do
      active_nodes = CorroPort.AnalyticsAggregator.get_active_nodes()

      json(conn, %{
        status: "success",
        active_nodes:
          Enum.map(active_nodes, fn node ->
            %{
              node_id: node.node_id,
              region: node.region,
              phoenix_port: node.phoenix_port,
              is_local: node.is_local
            }
          end),
        node_count: length(active_nodes),
        local_node_id: CorroPort.LocalNode.get_node_id(),
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          error: "Failed to get aggregation status: #{inspect(error)}",
          timestamp: DateTime.utc_now()
        })
    end
  end

  @doc """
  GET /api/analytics/health

  Health check endpoint to verify the analytics system is working.
  """
  def health(conn, _params) do
    try do
      # Quick health checks
      repo_status =
        case CorroPort.Analytics.Repo.query("SELECT 1") do
          {:ok, _} -> :ok
          _ -> :error
        end

      json(conn, %{
        status: "ok",
        node_id: CorroPort.LocalNode.get_node_id(),
        region: CorroPort.LocalNode.get_region(),
        database: repo_status,
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "error",
          error: inspect(error),
          timestamp: DateTime.utc_now()
        })
    end
  end

  @doc """
  GET /api/analytics/experiments/:experiment_id/export

  Export experiment data in the requested format.

  Query parameters:
  - `format` - Export format: "json" (default) or "csv"
  - `include_raw_events` - Include raw events: "true" (default) or "false"
  - `include_system_metrics` - Include system metrics: "true" (default) or "false"
  """
  def export_experiment(conn, params) do
    experiment_id = Map.get(params, "experiment_id")
    format = parse_format(Map.get(params, "format", "json"))
    include_raw_events = parse_boolean(Map.get(params, "include_raw_events", "true"))
    include_system_metrics = parse_boolean(Map.get(params, "include_system_metrics", "true"))

    opts = [
      include_raw_events: include_raw_events,
      include_system_metrics: include_system_metrics
    ]

    try do
      case Analytics.export_experiment(experiment_id, format, opts) do
        {:ok, data} when format == :json ->
          json(conn, data)

        {:ok, csv_data} when format == :csv ->
          conn
          |> put_resp_content_type("text/csv")
          |> put_resp_header("content-disposition", "attachment; filename=\"experiment_#{experiment_id}.csv\"")
          |> send_resp(200, csv_data)

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{
            status: "error",
            error: reason,
            timestamp: DateTime.utc_now()
          })
      end
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          error: "Failed to export experiment: #{inspect(error)}",
          timestamp: DateTime.utc_now()
        })
    end
  end

  @doc """
  GET /api/analytics/experiments/compare

  Export comparison of multiple experiments.

  Query parameters:
  - `ids` - Comma-separated list of experiment IDs
  - `format` - Export format: "json" (default) or "csv"
  """
  def export_comparison(conn, params) do
    experiment_ids =
      params
      |> Map.get("ids", "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    format = parse_format(Map.get(params, "format", "json"))

    if experiment_ids == [] do
      conn
      |> put_status(:bad_request)
      |> json(%{
        status: "error",
        error: "No experiment IDs provided. Use ?ids=exp1,exp2,exp3",
        timestamp: DateTime.utc_now()
      })
    else
      try do
        case Analytics.export_comparison(experiment_ids, format) do
          {:ok, data} when format == :json ->
            json(conn, data)

          {:ok, csv_data} when format == :csv ->
            conn
            |> put_resp_content_type("text/csv")
            |> put_resp_header("content-disposition", "attachment; filename=\"experiment_comparison.csv\"")
            |> send_resp(200, csv_data)

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              status: "error",
              error: reason,
              timestamp: DateTime.utc_now()
            })
        end
      rescue
        error ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            status: "error",
            error: "Failed to export comparison: #{inspect(error)}",
            timestamp: DateTime.utc_now()
          })
      end
    end
  end

  @doc """
  GET /api/analytics/experiments/list

  List all available experiments with basic information.
  """
  def list_experiments(conn, _params) do
    try do
      case Analytics.list_available_experiments() do
        {:ok, experiments} ->
          # Convert datetime fields to ISO8601
          experiments_json =
            Enum.map(experiments, fn exp ->
              %{
                experiment_id: exp.experiment_id,
                message_count: exp.message_count,
                send_count: exp.send_count,
                ack_count: exp.ack_count,
                time_range:
                  case exp.time_range do
                    %{start: start_time, end: end_time} ->
                      %{
                        start: format_datetime(start_time),
                        end: format_datetime(end_time)
                      }

                    nil ->
                      nil
                  end
              }
            end)

          json(conn, %{
            status: "success",
            experiments: experiments_json,
            count: length(experiments_json),
            timestamp: DateTime.utc_now()
          })

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            status: "error",
            error: reason,
            timestamp: DateTime.utc_now()
          })
      end
    rescue
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          error: "Failed to list experiments: #{inspect(error)}",
          timestamp: DateTime.utc_now()
        })
    end
  end

  # Private helpers

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_datetime(nil), do: nil
  defp format_datetime(other), do: other

  defp parse_format("json"), do: :json
  defp parse_format("csv"), do: :csv
  defp parse_format(_), do: :json

  defp parse_boolean("true"), do: true
  defp parse_boolean("false"), do: false
  defp parse_boolean(_), do: true
end

# Helper functions to extract display logic from ClusterLive template

defmodule CorroPortWeb.DisplayHelpers do
  @moduledoc """
  Helper functions for ClusterLive to determine display content and styling.
  Moves conditional logic out of the template for better maintainability.
  """

  @doc """
  Determines the CSS classes for refresh buttons based on data state.
  """
  def refresh_button_class(data, base_class \\ "btn btn-xs") do
    if has_error?(data) do
      "#{base_class} btn-error"
    else
      "#{base_class} btn-outline"
    end
  end

  @doc """
  Builds refresh button configuration for action buttons.
  """
  def refresh_button_config(data, action, label, icon) do
    %{
      action: action,
      label: label,
      icon: icon,
      class: refresh_button_class(data, "btn btn-xs"),
      show_warning: has_error?(data)
    }
  end

  @doc """
  Builds system button configuration (different error checking).
  """
  def system_button_config(data, action, label, icon) do
    %{
      action: action,
      label: label,
      icon: icon,
      class: system_refresh_button_class(data),
      show_warning: !is_nil(data.cache_status.error)
    }
  end

  @doc """
  Builds all alert configurations for display.
  """
  def build_all_alerts(expected_data, active_data, system_data) do
    [
      dns_alert_config(expected_data),
      cli_alert_config(active_data),
      system_alert_config(system_data)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Checks if data has an error state.
  """
  def has_error?(data) do
    case get_data_result(data) do
      {:error, _} -> true
      _ -> false
    end
  end

  @doc """
  Gets the error reason from data, returns nil if no error.
  """
  def get_error_reason(data) do
    case get_data_result(data) do
      {:error, reason} -> reason
      _ -> nil
    end
  end

  @doc """
  Determines if a warning indicator should be shown for data.
  """
  def show_warning?(data) do
    has_error?(data)
  end

  @doc """
  Gets the count from data result, handling error states.
  """
  def get_count(data, key) do
    case Map.get(data, key) do
      {:ok, list} when is_list(list) -> length(list)
      {:error, _} -> nil
      _ -> 0
    end
  end

  @doc """
  Formats a count for display, showing "?" for error states.
  """
  def format_count(data, key) do
    case get_count(data, key) do
      nil -> "?"
      count -> to_string(count)
    end
  end

  @doc """
  Gets display content for count with error styling.
  Returns a map with content and CSS class.
  """
  def count_display(data, key) do
    case get_count(data, key) do
      nil -> %{content: "?", class: "text-error"}
      count -> %{content: to_string(count), class: ""}
    end
  end

  @doc """
  Determines API health status display.
  """
  def api_health_display(system_data) do
    if system_data.cluster_info do
      %{
        content: "✓",
        class: "text-success",
        description: "connected"
      }
    else
      %{
        content: "✗",
        class: "text-error",
        description: "failed"
      }
    end
  end

  @doc """
  Formats cache status for display.
  """
  def cache_status_display(cache_status) do
    case cache_status do
      %{last_updated: nil} ->
        "Never loaded"

      %{last_updated: updated, error: nil} ->
        "Updated #{Calendar.strftime(updated, "%H:%M:%S")}"

      %{last_updated: updated, error: error} ->
        "Failed at #{Calendar.strftime(updated, "%H:%M:%S")} (#{format_error_reason(error)})"

      _ ->
        "Unknown status"
    end
  end

  @doc """
  Determines if an alert should be shown for data.
  """
  def show_alert?(data) do
    has_error?(data)
  end

  @doc """
  Gets alert configuration for DNS data.
  """
  def dns_alert_config(expected_data) do
    case get_error_reason(expected_data) do
      nil -> nil
      reason -> %{
        class: "alert alert-warning",
        icon: "hero-exclamation-triangle",
        title: "DNS Discovery Failed",
        message: "Error: #{format_error_reason(reason)} - Expected regions may be incomplete"
      }
    end
  end

  @doc """
  Gets alert configuration for CLI data.
  """
  def cli_alert_config(active_data) do
    case get_error_reason(active_data) do
      nil -> nil
      reason -> %{
        class: "alert alert-error",
        icon: "hero-exclamation-triangle",
        title: "CLI Data Failed",
        message: "Error: #{format_error_reason(reason)} - Active member list may be stale"
      }
    end
  end

  @doc """
  Gets alert configuration for system data.
  """
  def system_alert_config(system_data) do
    case system_data.cache_status.error do
      nil -> nil
      error -> %{
        class: "alert alert-warning",
        icon: "hero-exclamation-triangle",
        title: "System Data Issue",
        message: "Error: #{format_error_reason(error)} - Cluster info may be incomplete"
      }
    end
  end

  @doc """
  Builds display configuration for cluster summary stats.
  """
  def cluster_summary_stats(expected_data, active_data, system_data, expected_regions, active_regions) do
    expected_display = count_display(expected_data, :nodes)
    active_display = count_display(active_data, :members)
    api_health = api_health_display(system_data)

    %{
      expected: %{
        display: expected_display,
        regions_count: length(expected_regions)
      },
      active: %{
        display: active_display,
        regions_count: length(active_regions)
      },
      api_health: api_health,
      messages_count: length(system_data.latest_messages)
    }
  end

  @doc """
  Gets system info details for cluster summary.
  Returns nil if no cluster info available.
  """
  def system_info_details(system_data) do
    case system_data.cluster_info do
      nil -> nil
      cluster_info -> %{
        total_active_nodes: Map.get(cluster_info, "total_active_nodes", 0),
        active_member_count: Map.get(cluster_info, "active_member_count", 0),
        member_count: Map.get(cluster_info, "member_count", 0),
        peer_count: Map.get(cluster_info, "peer_count", 0)
      }
    end
  end

  @doc """
  Builds CLI member data for the CLIMembersTable component.
  """
  def build_cli_member_data(active_data) do
    case active_data.members do
      {:ok, members} ->
        %{
          members: members,
          member_count: length(members),
          status: :ok,
          last_updated: active_data.cache_status.last_updated,
          last_error: nil
        }

      {:error, reason} ->
        %{
          members: [],
          member_count: 0,
          status: :error,
          last_updated: active_data.cache_status.last_updated,
          last_error: reason
        }
    end
  end

  @doc """
  Extracts CLI error from active data for the CLIMembersTable component.
  """
  def extract_cli_error(active_data) do
    case active_data.members do
      {:ok, _} -> nil
      {:error, reason} -> reason
    end
  end

  @doc """
  Builds cache status display data for all data sources.
  """
  def all_cache_status(expected_data, active_data, system_data) do
    %{
      dns: cache_status_display(expected_data.cache_status),
      cli: cache_status_display(active_data.cache_status),
      system: cache_status_display(system_data.cache_status)
    }
  end

  @doc """
  Formats a timestamp for consistent display across the app.
  """
  def format_timestamp(nil), do: "Unknown"

  def format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> timestamp
    end
  end

  def format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  def format_timestamp(_), do: "Unknown"

  @doc """
  Formats error reasons consistently across the application.
  """
  def format_error_reason(reason) do
    case reason do
      :dns_failed -> "DNS lookup failed"
      :cli_timeout -> "CLI command timed out"
      {:cli_failed, _} -> "CLI command failed"
      {:parse_failed, _} -> "Failed to parse CLI output"
      :service_unavailable -> "Service unavailable"
      {:tracking_failed, _} -> "Failed to start tracking"
      {:cluster_api_failed, _} -> "Cluster API connection failed"
      {:fetch_exception, _} -> "System data fetch failed"
      _ -> "#{inspect(reason)}"
    end
  end

  # Private helper functions

  defp get_data_result(data) do
    # Try different keys that might contain the result
    Map.get(data, :nodes) || Map.get(data, :members) || {:ok, []}
  end

  # Private helper for system button class
  defp system_refresh_button_class(data) do
    base_class = "btn btn-xs"
    if data.cache_status.error do
      "#{base_class} btn-error"
    else
      "#{base_class} btn-outline"
    end
  end
end

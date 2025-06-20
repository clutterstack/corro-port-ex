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
        icon: "✓",
        class: "text-success",
        description: "connected"
      }
    else
      %{
        icon: "✗",
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

  # Private helper functions

  defp get_data_result(data) do
    # Try different keys that might contain the result
    Map.get(data, :nodes) || Map.get(data, :members) || {:ok, []}
  end

  defp format_error_reason(reason) do
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
end

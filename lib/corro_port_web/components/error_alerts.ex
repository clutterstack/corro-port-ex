defmodule CorroPortWeb.ErrorAlerts do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders error alerts for different data sources with specific styling.
  """
  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true

  def error_alerts(assigns) do
    ~H"""
    <div class="space-y-4">
      <!-- DNS Discovery Error -->
      <.error_alert
        :if={dns_has_error?(@expected_data)}
        type={:warning}
        title="DNS Discovery Failed"
        message={format_dns_error(@expected_data)}
      />

      <!-- CLI Data Error -->
      <.error_alert
        :if={cli_has_error?(@active_data)}
        type={:error}
        title="CLI Data Failed"
        message={format_cli_error(@active_data)}
      />
    </div>
    """
  end

  # Private error alert component
  attr :type, :atom, values: [:warning, :error], required: true
  attr :title, :string, required: true
  attr :message, :string, required: true

  defp error_alert(assigns) do
    ~H"""
    <div class={alert_class(@type)}>
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <div>
        <div class="font-semibold">{@title}</div>
        <div class="text-sm">{@message}</div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp dns_has_error?(expected_data) do
    match?({:error, _}, Map.get(expected_data, :nodes))
  end

  defp cli_has_error?(active_data) do
    match?({:error, _}, Map.get(active_data, :members))
  end

  defp format_dns_error(expected_data) do
    case Map.get(expected_data, :nodes) do
      {:error, reason} -> "Error: #{format_error_reason(reason)} - Expected regions may be incomplete"
      _ -> ""
    end
  end

  defp format_cli_error(active_data) do
    case Map.get(active_data, :members) do
      {:error, reason} -> "Error: #{format_error_reason(reason)} - Active member list may be stale"
      _ -> ""
    end
  end

  defp format_error_reason(reason) do
    case reason do
      :dns_failed -> "DNS lookup failed"
      :cli_timeout -> "CLI command timed out"
      {:cli_failed, _} -> "CLI command failed"
      {:parse_failed, _} -> "Failed to parse CLI output"
      :service_unavailable -> "Service unavailable"
      _ -> "#{inspect(reason)}"
    end
  end

  defp alert_class(:warning), do: "alert alert-warning"
  defp alert_class(:error), do: "alert alert-error"
end

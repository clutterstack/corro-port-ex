defmodule CorroPortWeb.CacheStatus do
  use Phoenix.Component

  @doc """
  Renders cache status indicators for DNS and CLI data sources.
  """
  attr :dns_data, :map, required: true
  attr :cli_data, :map, required: true

  def cache_status(assigns) do
    ~H"""
    <div class="flex gap-4 text-xs text-base-content/70">
      <.cache_status_item
        label="DNS Cache"
        status={Map.get(@dns_data, :cache_status)}
      />

      <.cache_status_item
        label="CLI Cache"
        status={Map.get(@cli_data, :cache_status)}
      />
    </div>
    """
  end

  # Individual cache status item
  attr :label, :string, required: true
  attr :status, :map, required: true

  defp cache_status_item(assigns) do
    status_text = format_cache_status(assigns.status)
    assigns = assign(assigns, :status_text, status_text)

    ~H"""
    <div>
      <strong>{@label}:</strong>
      {@status_text}
    </div>
    """
  end

  # Helper function to format cache status
  defp format_cache_status(status) when is_map(status) do
    case status do
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

  defp format_cache_status(_), do: "Unknown status"

  defp format_error_reason(error) do
    case error do
      :dns_failed -> "DNS lookup failed"
      :cli_timeout -> "CLI command timed out"
      {:cli_failed, _} -> "CLI command failed"
      {:parse_failed, _} -> "Failed to parse CLI output"
      :service_unavailable -> "Service unavailable"
      _ -> "#{inspect(error)}"
    end
  end
end

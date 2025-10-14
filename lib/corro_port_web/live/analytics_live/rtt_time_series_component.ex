defmodule CorroPortWeb.AnalyticsLive.RttTimeSeriesComponent do
  @moduledoc """
  Phoenix Component for rendering RTT time series chart.

  Shows round-trip acknowledgment times over time for each node. This helps identify
  performance patterns and understand cluster latency characteristics.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.TimeSeries

  @doc """
  Renders the RTT time series chart showing round-trip times for each node.
  """
  attr :rtt_time_series, :list, required: true
  attr :receipt_time_series, :list, default: []

  def rtt_time_series_chart(assigns) do
    ~H"""
    <%= if @rtt_time_series != [] or @receipt_time_series != [] do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-2">Latency Over Time by Node</h3>
          <p class="text-sm text-base-content/70 mb-4">
            Round-trip times for acknowledgements from each node over the experiment duration.
          </p>

          <!-- SVG Time Series Plot -->
          <div class="w-full" style="height: 400px;">
            <TimeSeries.render_rtt_time_series rtt_time_series={@rtt_time_series} receipt_time_series={@receipt_time_series} />
          </div>

          <div class="mt-4 text-sm text-base-content/70">
            Each colour represents a different node. Lines connect data points to show timing trends.
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end

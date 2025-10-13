defmodule CorroPortWeb.AnalyticsLive.RttTimeSeriesComponent do
  @moduledoc """
  Phoenix Component for rendering combined RTT and propagation delay time series chart.

  Shows both round-trip acknowledgment times (solid lines) and message propagation
  delays (dotted lines) on the same chart for direct comparison. This helps identify
  performance patterns and understand how much of the RTT is due to propagation vs
  acknowledgment processing.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.TimeSeries

  @doc """
  Renders the combined latency time series chart showing RTT and propagation delays.
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
            Combined view showing RTT (solid lines) and propagation delays (dotted lines).
            Compare to see how much of total latency is gossip propagation vs ack processing.
          </p>

          <!-- SVG Time Series Plot -->
          <div class="w-full" style="height: 400px;">
            <TimeSeries.render_rtt_time_series rtt_time_series={@rtt_time_series} receipt_time_series={@receipt_time_series} />
          </div>

          <div class="mt-4 text-sm text-base-content/70">
            Each colour represents a different node. Solid lines show full round-trip time, dotted lines show
            one-way propagation delay. Gap between them reveals ack processing and return path latency.
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end

defmodule CorroPortWeb.AnalyticsLive.RttTimeSeriesComponent do
  @moduledoc """
  Phoenix Component for rendering RTT time series chart.

  Shows response time trends over time by node, helping identify
  performance degradation as experiments progress.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.TimeSeries

  @doc """
  Renders the RTT time series chart showing performance over time.
  """
  attr :rtt_time_series, :list, required: true

  def rtt_time_series_chart(assigns) do
    ~H"""
    <%= if @rtt_time_series != [] do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-2">RTT Over Time by Node</h3>
          <p class="text-sm text-base-content/70 mb-4">
            Response time trends showing if nodes slow down as the experiment progresses
          </p>

          <!-- SVG Time Series Plot -->
          <div class="w-full" style="height: 400px;">
            <TimeSeries.render_rtt_time_series rtt_time_series={@rtt_time_series} />
          </div>

          <div class="mt-4 text-sm text-base-content/70">
            Each line represents a different responding node. Look for upward trends that might indicate
            degradation due to load or gossip overhead.
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end

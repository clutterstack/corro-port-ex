defmodule CorroPortWeb.AnalyticsLive.ReceiptTimeSeriesComponent do
  @moduledoc """
  Phoenix Component for rendering receipt time (propagation delay) series chart.

  Shows propagation delay trends over time by receiving node, revealing how
  gossip propagation patterns change as experiments progress. Uses the same
  X-axis as the RTT chart for easy comparison.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.ReceiptTimeSeries

  @doc """
  Renders the receipt time series chart showing propagation delays over time.
  """
  attr :receipt_time_series, :list, required: true

  def receipt_time_series_chart(assigns) do
    ~H"""
    <%= if @receipt_time_series != [] do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-2">Message Propagation Delay Over Time by Node</h3>
          <p class="text-sm text-base-content/70 mb-4">
            Propagation patterns showing when messages arrived at each node via gossip.
            X-axis matches RTT chart for direct comparison.
          </p>

          <!-- SVG Time Series Plot -->
          <div class="w-full" style="height: 400px;">
            <ReceiptTimeSeries.render_receipt_time_series receipt_time_series={@receipt_time_series} />
          </div>

          <div class="mt-4 text-sm text-base-content/70">
            Each line represents a different receiving node. Patterns reveal gossip topology effects -
            nodes with direct peer connections show lower, more consistent delays while others may show
            periodic spikes from multi-hop propagation.
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end

defmodule CorroPortWeb.AnalyticsLive.LatencyHistogramComponent do
  @moduledoc """
  Phoenix Component for rendering latency histogram chart.

  Displays the distribution of round-trip times across all acknowledgements
  with percentile markers (P50, P95, P99).
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.HistogramVl

  @doc """
  Renders the latency histogram chart with percentile markers.
  """
  attr :latency_histogram, :map, required: true

  def latency_histogram_chart(assigns) do
    ~H"""
    <%= if @latency_histogram && @latency_histogram.total_count > 0 do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-2">Latency Distribution</h3>
          <p class="text-sm text-base-content/70 mb-4">
            Distribution of round-trip times across all {@latency_histogram.total_count} acknowledgements
          </p>

          <!-- VegaLite Histogram -->
          <div class="w-full">
            <HistogramVl.render_latency_histogram histogram={@latency_histogram} />
          </div>

          <!-- Percentile Markers Legend -->
          <div class="mt-4 flex items-center gap-6 text-sm">
            <div class="flex items-center gap-2">
              <div class="w-0.5 h-4 bg-info"></div>
              <span class="text-base-content/70">
                P50 (median): <span class="font-medium">{@latency_histogram.percentiles.p50}ms</span>
              </span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-0.5 h-4 bg-warning"></div>
              <span class="text-base-content/70">
                P95: <span class="font-medium">{@latency_histogram.percentiles.p95}ms</span>
              </span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-0.5 h-4 bg-error"></div>
              <span class="text-base-content/70">
                P99: <span class="font-medium">{@latency_histogram.percentiles.p99}ms</span>
              </span>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end

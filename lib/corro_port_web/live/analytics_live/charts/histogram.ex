defmodule CorroPortWeb.AnalyticsLive.Charts.Histogram do
  @moduledoc """
  SVG histogram chart rendering for latency distribution.

  Renders a vertical bar chart showing the distribution of round-trip times
  with percentile markers (P50, P95, P99) and colour-coded buckets.
  """

  use Phoenix.Component

  @doc """
  Renders an SVG histogram showing latency distribution.

  The histogram includes:
  - Vertical bars for each latency bucket
  - Y-axis with count labels
  - X-axis with latency range labels
  - Colour-coded bars (green < 50ms, yellow < 200ms, orange < 500ms, red >= 500ms)
  - Percentile markers (P50, P95, P99) as dashed vertical lines

  ## Parameters

    * `histogram` - Map containing:
      * `:buckets` - List of bucket maps with `:min`, `:max`, `:count`, `:label`
      * `:max_count` - Maximum count value for Y-axis scaling
      * `:total_count` - Total number of data points
      * `:percentiles` - Map with `:p50`, `:p95`, `:p99` values
  """
  attr :histogram, :map, required: true
  def render_latency_histogram(assigns) do
    histogram = assigns.histogram
    buckets = histogram.buckets
    chart_height = 250
    chart_width = 800
    padding = %{top: 20, right: 20, bottom: 40, left: 60}

    plot_width = chart_width - padding.left - padding.right
    plot_height = chart_height - padding.top - padding.bottom

    buckets = histogram.buckets
    max_count = histogram.max_count
    bucket_count = length(buckets)

    bar_width = if bucket_count > 0, do: plot_width / bucket_count * 0.8, else: 0
    bar_spacing = if bucket_count > 0, do: plot_width / bucket_count, else: 0

    assigns = %{
      chart_width: chart_width,
      chart_height: chart_height,
      padding: padding,
      plot_width: plot_width,
      plot_height: plot_height,
      buckets: buckets,
      max_count: max_count,
      bar_width: bar_width,
      bar_spacing: bar_spacing,
      percentiles: histogram.percentiles
    }

    ~H"""
    <svg width="100%" height="100%" viewBox={"0 0 #{@chart_width} #{@chart_height}"} class="border border-gray-200 rounded">
      <!-- Y-axis -->
      <line
        x1={@padding.left}
        y1={@padding.top}
        x2={@padding.left}
        y2={@chart_height - @padding.bottom}
        stroke="#9CA3AF"
        stroke-width="1"
      />
      <!-- X-axis -->
      <line
        x1={@padding.left}
        y1={@chart_height - @padding.bottom}
        x2={@chart_width - @padding.right}
        y2={@chart_height - @padding.bottom}
        stroke="#9CA3AF"
        stroke-width="1"
      />

      <!-- Y-axis label -->
      <text x="20" y={@padding.top + @plot_height / 2} text-anchor="middle" transform={"rotate(-90, 20, #{@padding.top + @plot_height / 2})"} class="text-xs fill-gray-600">
        Count
      </text>

      <!-- X-axis label -->
      <text x={@padding.left + @plot_width / 2} y={@chart_height - 5} text-anchor="middle" class="text-xs fill-gray-600">
        Latency (ms)
      </text>

      <!-- Y-axis ticks -->
      <%= for i <- 0..5 do %>
        <% y = @chart_height - @padding.bottom - (@plot_height * i / 5) %>
        <% value = Float.round(@max_count * i / 5, 1) %>
        <line x1={@padding.left - 5} y1={y} x2={@padding.left} y2={y} stroke="#9CA3AF" stroke-width="1" />
        <text x={@padding.left - 10} y={y + 4} text-anchor="end" class="text-xs fill-gray-600">
          {value}
        </text>
      <% end %>

      <!-- Bars -->
      <%= for {bucket, index} <- Enum.with_index(@buckets) do %>
        <% x = @padding.left + index * @bar_spacing %>
        <% bar_height = if @max_count > 0, do: bucket.count / @max_count * @plot_height, else: 0 %>
        <% y = @chart_height - @padding.bottom - bar_height %>
        <% fill_colour = bucket_fill_colour(bucket.min) %>

        <!-- Bar -->
        <rect
          x={x}
          y={y}
          width={@bar_width}
          height={bar_height}
          fill={fill_colour}
          opacity="0.8"
        />

        <!-- Count label on top of bar -->
        <%= if bucket.count > 0 do %>
          <text x={x + @bar_width / 2} y={y - 5} text-anchor="middle" class="text-xs fill-gray-700 font-medium">
            {bucket.count}
          </text>
        <% end %>

        <!-- X-axis label -->
        <text
          x={x + @bar_width / 2}
          y={@chart_height - @padding.bottom + 15}
          text-anchor="middle"
          class="text-xs fill-gray-600"
          transform={"rotate(-45, #{x + @bar_width / 2}, #{@chart_height - @padding.bottom + 15})"}
        >
          {bucket.label}
        </text>
      <% end %>

      <!-- Percentile markers -->
      <%= for {percentile_name, percentile_value, colour} <- [{"P50", @percentiles.p50, "#3B82F6"}, {"P95", @percentiles.p95, "#F97316"}, {"P99", @percentiles.p99, "#EF4444"}] do %>
        <%= if percentile_value do %>
          <% x_pos = calculate_percentile_position(percentile_value, @buckets, @bar_spacing, @padding.left) %>
          <line
            x1={x_pos}
            y1={@padding.top}
            x2={x_pos}
            y2={@chart_height - @padding.bottom}
            stroke={colour}
            stroke-width="2"
            stroke-dasharray="5,5"
            opacity="0.7"
          />
          <text x={x_pos + 5} y={@padding.top + 15} class="text-xs font-medium" fill={colour}>
            {percentile_name}
          </text>
        <% end %>
      <% end %>
    </svg>
    """
  end

  @doc """
  Returns the fill colour for a histogram bucket based on latency threshold.

  Colour scheme:
  - Green (#10B981): < 50ms (excellent)
  - Yellow (#F59E0B): 50-200ms (good)
  - Orange (#F97316): 200-500ms (fair)
  - Red (#EF4444): >= 500ms (slow)
  """
  def bucket_fill_colour(min_latency) do
    cond do
      min_latency < 50 -> "#10B981"
      min_latency < 200 -> "#F59E0B"
      min_latency < 500 -> "#F97316"
      true -> "#EF4444"
    end
  end

  @doc """
  Calculates the X position for a percentile marker on the histogram.

  Finds which bucket the percentile falls into and returns the centre
  position of that bucket.

  Returns left_padding if the percentile doesn't fall into any bucket.
  """
  def calculate_percentile_position(percentile_value, buckets, bar_spacing, left_padding) do
    # Find which bucket the percentile falls into
    bucket_index =
      buckets
      |> Enum.find_index(fn bucket ->
        case bucket.max do
          :infinity -> percentile_value >= bucket.min
          max_val -> percentile_value >= bucket.min && percentile_value < max_val
        end
      end)

    case bucket_index do
      nil -> left_padding
      index -> left_padding + index * bar_spacing + bar_spacing / 2
    end
  end
end

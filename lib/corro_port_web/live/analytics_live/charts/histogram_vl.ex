defmodule CorroPortWeb.AnalyticsLive.Charts.HistogramVl do
  @moduledoc """
  VegaLite histogram chart rendering for latency distribution.

  Renders an interactive vertical bar chart showing the distribution of round-trip times
  with percentile markers (P50, P95, P99) and colour-coded buckets.

  This replaces the SVG-based implementation with VegaLite for better interactivity,
  tooltips, and automatic scaling.
  """

  use Phoenix.Component
  alias VegaLite, as: Vl
  alias CorroPortWeb.AnalyticsLive.Charts.VegaLiteHelper

  @doc """
  Renders a VegaLite histogram showing latency distribution.

  The histogram includes:
  - Vertical bars for each latency bucket
  - Automatic Y-axis scaling with count labels
  - X-axis with latency range labels
  - Colour-coded bars (green < 50ms, yellow < 200ms, orange < 500ms, red >= 500ms)
  - Percentile markers (P50, P95, P99) as rule marks
  - Interactive tooltips showing bucket range and count

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

    if histogram.total_count == 0 do
      ~H"""
      <div class="text-base-content/50 text-center py-8">
        No latency data available
      </div>
      """
    else
      # Prepare bucket data for VegaLite
      # Add index to preserve bucket order for ordinal x-axis
      bucket_data =
        histogram.buckets
        |> Enum.with_index()
        |> Enum.map(fn {bucket, index} ->
          %{
            "label" => bucket.label,
            "min" => bucket.min,
            "max" => if(bucket.max == :infinity, do: 10000, else: bucket.max),
            "count" => bucket.count,
            "colour" => VegaLiteHelper.latency_colour(bucket.min),
            "order" => index
          }
        end)

      # Prepare percentile data for rule marks
      percentile_data =
        [
          %{"name" => "P50", "value" => histogram.percentiles.p50, "colour" => "#3B82F6"},
          %{"name" => "P95", "value" => histogram.percentiles.p95, "colour" => "#F97316"},
          %{"name" => "P99", "value" => histogram.percentiles.p99, "colour" => "#EF4444"}
        ]
        |> Enum.reject(fn p -> is_nil(p["value"]) end)

      # Build main histogram chart layer (without top-level config for layering)
      histogram_layer =
        Vl.new()
        |> Vl.data_from_values(bucket_data)
        |> Vl.mark(:bar, opacity: 0.8)
        |> Vl.encode_field(:x, "label",
          type: :ordinal,
          title: "Latency (ms)",
          axis: [label_angle: -45],
          sort: [field: "order", order: :ascending]
        )
        |> Vl.encode_field(:y, "count",
          type: :quantitative,
          title: "Count"
        )
        |> Vl.encode_field(:color, "colour",
          type: :nominal,
          scale: nil,
          legend: nil
        )
        |> Vl.encode(:tooltip, [
          [field: "label", type: :ordinal, title: "Range"],
          [field: "count", type: :quantitative, title: "Count"]
        ])

      # Build percentile rule marks layer (without top-level config for layering)
      percentile_layer =
        if percentile_data != [] do
          Vl.new()
          |> Vl.data_from_values(percentile_data)
          |> Vl.mark(:rule, stroke_width: 2, stroke_dash: [5, 5], opacity: 0.7)
          |> Vl.encode_field(:x, "value",
            type: :quantitative,
            title: "Latency (ms)"
          )
          |> Vl.encode_field(:color, "colour",
            type: :nominal,
            scale: nil,
            legend: nil
          )
          |> Vl.encode(:tooltip, [
            [field: "name", type: :nominal, title: "Percentile"],
            [field: "value", type: :quantitative, title: "Latency (ms)", format: ".1f"]
          ])
        else
          nil
        end

      # Combine layers first, then apply config
      layers = if percentile_layer, do: [histogram_layer, percentile_layer], else: [histogram_layer]

      spec =
        Vl.new(width: 800, height: 250, background: "transparent", padding: 20)
        |> Vl.layers(layers)
        |> Vl.config(
          axis: [
            grid_color: "#374151",
            grid_opacity: 0.3,
            tick_color: "#9CA3AF",
            label_color: "#9CA3AF",
            title_color: "#9CA3AF",
            domain_color: "#9CA3AF"
          ],
          legend: [
            label_color: "#9CA3AF",
            title_color: "#9CA3AF"
          ],
          view: [stroke: "#374151"]
        )

      assigns = assign(assigns, :spec, spec)

      ~H"""
      <VegaLiteHelper.vega_chart
        spec={@spec}
        class="w-full rounded-lg border border-base-content/10 bg-base-100 p-4"
      />
      """
    end
  end
end

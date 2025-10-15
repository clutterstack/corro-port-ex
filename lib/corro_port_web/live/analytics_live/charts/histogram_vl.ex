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
  - Vertical bars positioned at bucket minimum with calculated pixel widths
  - Bar width automatically scaled based on bucket size and chart dimensions
  - Automatic Y-axis scaling with count labels
  - Quantitative X-axis with explicit domain matching data bounds
  - Colour-coded bars (green < 300ms, yellow < 600ms, orange < 900ms, red >= 900ms)
  - Percentile markers (P50, P95, P99) as vertical rule marks
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
      # All buckets now have explicit numeric boundaries (no :infinity)
      bucket_data =
        histogram.buckets
        |> Enum.map(fn bucket ->
          width = bucket.max - bucket.min

          %{
            "label" => bucket.label,
            "min" => bucket.min,
            "max" => bucket.max,
            "width" => width,
            "count" => bucket.count,
            "colour" => VegaLiteHelper.latency_colour(bucket.min)
          }
        end)

      # Calculate actual data domain for x-axis (avoid VegaLite auto-padding)
      x_min = histogram.buckets |> Enum.map(& &1.min) |> Enum.min()
      x_max = histogram.buckets |> Enum.map(& &1.max) |> Enum.max()

      # Calculate typical bucket width for bar sizing
      bucket_width =
        bucket_data
        |> Enum.map(& &1["width"])
        |> Enum.filter(&(&1 > 0))
        |> then(fn widths ->
          if widths == [], do: 100, else: Enum.min(widths)
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
      # Position bars at bucket min with explicit width
      # VegaLite's size encoding uses pixels, need to calculate scale factor
      # For 800px width chart spanning (x_max - x_min), pixels per ms = 800 / (x_max - x_min)
      px_per_ms = 800 / (x_max - x_min)
      bar_width_px = bucket_width * px_per_ms * 0.95  # 95% to add small gaps

      histogram_layer =
        Vl.new()
        |> Vl.data_from_values(bucket_data)
        |> Vl.mark(:bar, opacity: 0.8, size: bar_width_px)
        |> Vl.encode_field(:x, "min",
          type: :quantitative,
          title: "Latency (ms)",
          scale: [domain: [x_min, x_max]],
          axis: [label_flush: true, tick_count: 10]
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
          [field: "label", type: :nominal, title: "Range"],
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
            title: "Latency (ms)",
            scale: [domain: [x_min, x_max]]
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
        VegaLiteHelper.base_config(width: 800, height: 250)
        |> Vl.layers(layers)

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

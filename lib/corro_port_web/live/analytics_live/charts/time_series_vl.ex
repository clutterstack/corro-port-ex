defmodule CorroPortWeb.AnalyticsLive.Charts.TimeSeriesVl do
  @moduledoc """
  VegaLite time series chart rendering for RTT over time.

  Renders an interactive line chart showing how round-trip acknowledgement times change
  over the course of an experiment, with separate lines for each responding node.

  This replaces the SVG-based implementation with VegaLite for better interactivity,
  tooltips, zoom/pan capabilities, and automatic axis formatting.
  """

  use Phoenix.Component
  alias VegaLite, as: Vl
  alias CorroPortWeb.AnalyticsLive.Charts.VegaLiteHelper

  @doc """
  Renders a VegaLite time series plot showing RTT over time for each node.

  The chart includes:
  - Interactive line plots for RTT progression
  - Data points as circles
  - Automatic axis scaling and formatting
  - Tooltips showing node, time, and latency
  - Legend identifying each node's line by colour
  - Pan and zoom capabilities

  Returns a message if there is no data available.

  ## Parameters

    * `rtt_time_series` - List of series maps for RTT data, each containing:
      * `:node_id` - Identifier for the responding node
      * `:data_points` - List of point maps with `:send_time` (DateTime) and `:rtt_ms` (number)
    * `receipt_time_series` - Legacy parameter, no longer used (kept for API compatibility)
  """
  attr :rtt_time_series, :list, required: true
  attr :receipt_time_series, :list, default: []

  def render_rtt_time_series(assigns) do
    rtt_time_series = assigns.rtt_time_series
    all_rtt_points = Enum.flat_map(rtt_time_series, & &1.data_points)

    if all_rtt_points == [] do
      ~H"""
      <div class="text-base-content/50 text-center py-8">
        No timing data available
      </div>
      """
    else
      # Find experiment start time (earliest send_time across all data)
      experiment_start =
        all_rtt_points
        |> Enum.map(& &1.send_time)
        |> Enum.min(DateTime)

      # Prepare data for VegaLite - convert times to milliseconds elapsed from start
      chart_data =
        rtt_time_series
        |> Enum.flat_map(fn series ->
          Enum.map(series.data_points, fn point ->
            elapsed_ms = DateTime.diff(point.send_time, experiment_start, :millisecond)
            %{
              "node_id" => series.node_id,
              "elapsed_ms" => elapsed_ms,
              "rtt_ms" => point.rtt_ms
            }
          end)
        end)

      # Build VegaLite spec
      spec =
        VegaLiteHelper.base_config(width: 800, height: 400)
        |> Vl.data_from_values(chart_data)
        |> Vl.param("node_focus", select: [type: :point, fields: ["node_id"], bind: "legend"])
        |> Vl.mark(:line, point: true, stroke_width: 2)
        |> Vl.encode_field(:x, "elapsed_ms",
          type: :quantitative,
          title: "Time (ms)"
        )
        |> Vl.encode_field(:y, "rtt_ms",
          type: :quantitative,
          title: "RTT (ms)",
          scale: [zero: false]
        )
        |> Vl.encode_field(:color, "node_id",
          type: :nominal,
          title: "Node",
          scale: [range: VegaLiteHelper.node_colours()]
        )
        |> Vl.encode(:opacity,
          condition: [param: "node_focus", value: 0.9],
          value: 0.15
        )
        |> Vl.encode(:tooltip, [
          [field: "node_id", type: :nominal, title: "Node"],
          [field: "elapsed_ms", type: :quantitative, title: "Time (ms)", format: ".0f"],
          [field: "rtt_ms", type: :quantitative, title: "Latency (ms)", format: ".1f"]
        ])

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

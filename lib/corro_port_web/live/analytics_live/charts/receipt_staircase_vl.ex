defmodule CorroPortWeb.AnalyticsLive.Charts.ReceiptStaircaseVl do
  @moduledoc """
  Compact VegaLite bar chart showing message receipt patterns.

  Visualises message receipt times as an interactive bar graph where:
  - X-axis shows message index (1, 2, 3, ...)
  - Y-axis shows time since experiment start (milliseconds from first message send)
  - Bar height represents when each message was received at the remote node
  - Messages arriving together (batching) will have similar bar heights

  The batching pattern becomes visually obvious when multiple consecutive bars
  have the same or very similar heights, showing that Corrosion delivered them
  together via gossip.

  Designed to be compact (70-80px per node) so many nodes can be displayed simultaneously.

  This replaces the SVG-based implementation with VegaLite for better interactivity,
  tooltips showing exact timing, and automatic axis formatting.
  """

  use Phoenix.Component
  alias VegaLite, as: Vl
  alias CorroPortWeb.AnalyticsLive.Charts.VegaLiteHelper

  @doc """
  Renders a compact receipt time chart for a single node's receipt pattern.

  ## Parameters

    * `node_id` - The receiving node identifier
    * `delays` - List of time offsets from experiment start in temporal order (milliseconds)
    * `stats` - Statistics map containing min/max/p95 values
  """
  attr :node_id, :string, required: true
  attr :delays, :list, required: true
  attr :stats, :map, required: true

  def render_staircase(assigns) do
    time_offsets = assigns.delays  # Note: these are time offsets, not delays
    stats = assigns.stats

    if time_offsets == [] do
      ~H"""
      <div class="text-base-content/50 text-center py-4 text-sm">
        No data for {@node_id}
      </div>
      """
    else
      # Prepare data for VegaLite
      chart_data =
        time_offsets
        |> Enum.with_index(1)
        |> Enum.map(fn {time_offset, index} ->
          %{
            "message_index" => index,
            "time_offset_ms" => time_offset,
            "tooltip_label" => "Msg #{index}: +#{time_offset}ms"
          }
        end)

      # Colour based on the latest arrival offset
      bar_colour = VegaLiteHelper.time_offset_colour(stats.max_delay_ms)

      # Build VegaLite spec - compact layout
      spec =
        Vl.new(
          width: 800,
          height: 70,
          background: "transparent",
          padding: %{top: 5, right: 10, bottom: 25, left: 50}
        )
        |> Vl.data_from_values(chart_data)
        #|> Vl.mark(:bar, opacity: 0.8, color: "black", width: %{band: 0.9})
        |> Vl.mark(:tick,
          color: bar_colour,
          width: %{band: 0.95},
          thickness: 4
        )
        |> Vl.encode_field(:x, "message_index",
          type: :ordinal,
          title: "Message",
          axis: [grid: true],
          scale: [padding_inner: 0, padding_outer: 0]
        )
        |> Vl.encode_field(:y, "time_offset_ms",
          type: :quantitative,
          title: "Time (ms)",
          scale: [zero: false]
        )
        |> Vl.encode(:tooltip, [
          [field: "tooltip_label", type: :nominal, title: "Message"]
        ])
        |> Vl.config(
          axis: [
            grid_color: "#374151",
            grid_opacity: 0.3,
            tick_color: "#9CA3AF",
            label_color: "#9CA3AF",
            title_color: "#9CA3AF",
            title_font_size: 11,
            label_font_size: 10,
            domain_color: "#9CA3AF"
          ],
          view: [stroke: "#374151"]
        )

      assigns = assign(assigns, :spec, spec)

      ~H"""
      <div class="mb-3 p-3 bg-base-300 rounded-lg">
        <!-- Node header with summary stats -->
        <div class="flex items-center justify-between mb-2">
          <span class="font-mono font-medium text-sm">{@node_id}</span>
          <span class="text-xs text-base-content/70">
            {length(@delays)} msgs · first {@stats.min_delay_ms}ms · last {@stats.max_delay_ms}ms
          </span>
        </div>

        <!-- VegaLite staircase chart -->
        <VegaLiteHelper.vega_chart
          spec={@spec}
          class="rounded border border-base-content/10 bg-base-100"
        />
      </div>
      """
    end
  end
end

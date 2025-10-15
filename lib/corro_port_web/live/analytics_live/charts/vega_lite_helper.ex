defmodule CorroPortWeb.AnalyticsLive.Charts.VegaLiteHelper do
  @moduledoc """
  Shared VegaLite configuration and helpers for chart generation.

  Provides:
  - Colour palettes matching existing SVG chart colours
  - Common chart configuration (theme, sizing, padding)
  - Utility functions for building VegaLite specs
  - Component helper for embedding VegaLite charts in LiveViews
  """

  use Phoenix.Component
  alias VegaLite, as: Vl

  @doc """
  Node colour palette matching the existing SVG charts.

  Returns a list of hex colours used for distinguishing different nodes
  in multi-series charts.
  """
  def node_colours do
    [
      "#3B82F6",  # Blue
      "#10B981",  # Green
      "#F59E0B",  # Amber/Yellow
      "#EF4444",  # Red
      "#8B5CF6",  # Purple
      "#EC4899",  # Pink
      "#14B8A6",  # Teal
      "#F97316"   # Orange
    ]
  end

  @doc """
  Latency-based colour scheme for histogram buckets.

  Returns colour based on latency threshold:
  - Green: < 300ms (excellent)
  - Yellow: 300-600ms (good)
  - Orange: 600-900ms (fair)
  - Red: >= 900ms (slow)
  """
  def latency_colour(min_latency) when is_number(min_latency) do
    cond do
      min_latency < 300 -> "#10B981"
      min_latency < 600 -> "#F59E0B"
      min_latency < 900 -> "#F97316"
      true -> "#EF4444"
    end
  end

  @doc """
  Time offset colour scheme for receipt patterns.

  Earlier arrivals are better (green), later are worse (red).
  Thresholds based on typical experiment duration.
  """
  def time_offset_colour(avg_offset_ms) when is_number(avg_offset_ms) do
    cond do
      avg_offset_ms < 100 -> "#10B981"   # Very early - green
      avg_offset_ms < 500 -> "#F59E0B"   # Medium time - yellow
      avg_offset_ms < 2000 -> "#F97316"  # Later - orange
      true -> "#EF4444"                   # Very late - red
    end
  end

  @doc """
  Common chart configuration for VegaLite specs.

  Provides consistent sizing, padding, and theme settings across all charts.

  ## Options

    * `:width` - Chart width in pixels (default: 800)
    * `:height` - Chart height in pixels (default: 400)
    * `:background` - Background colour (default: transparent)
    * `:padding` - Padding around plot area (default: 20)
  """
  def base_config(opts \\ []) do
    width = Keyword.get(opts, :width, 800)
    height = Keyword.get(opts, :height, 400)
    background = Keyword.get(opts, :background, "transparent")
    padding = Keyword.get(opts, :padding, 20)

    Vl.new(
      width: width,
      height: height,
      background: background,
      padding: padding
    )
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
      view: [
        stroke: "#374151"
      ]
    )
  end

  @doc """
  Phoenix component for rendering VegaLite charts in LiveViews.

  Embeds a VegaLite chart using the VegaLiteChart JavaScript hook.
  The chart will automatically re-render when the spec changes.

  ## Attributes

    * `spec` - VegaLite specification (required)
    * `class` - Additional CSS classes (optional)

  ## Example

      <VegaLiteHelper.vega_chart
        spec={@chart_spec}
        class="my-4 rounded-lg border border-base-content/10"
      />
  """
  attr :spec, :map, required: true
  attr :class, :string, default: ""

  def vega_chart(assigns) do
    # Convert VegaLite spec to JSON string
    spec_json = Jason.encode!(VegaLite.to_spec(assigns.spec))

    assigns = assign(assigns, :spec_json, spec_json)

    ~H"""
    <div
      phx-hook="VegaLiteChart"
      data-spec={@spec_json}
      class={@class}
      id={"vega-chart-#{:erlang.phash2(@spec)}"}
    >
    </div>
    """
  end

  @doc """
  Generates a colour scale for categorical node data.

  Returns a VegaLite colour scale configuration using the node colour palette.
  """
  def node_colour_scale do
    %{
      "scale" => %{
        "domain" => ["node1", "node2", "node3", "node4", "node5", "node6", "node7", "node8"],
        "range" => node_colours()
      }
    }
  end

  @doc """
  Adds axis titles to a VegaLite spec.

  ## Options

    * `:x` - X-axis title
    * `:y` - Y-axis title
  """
  def add_axis_titles(vl, opts) do
    vl = if x_title = opts[:x], do: Vl.encode_field(vl, :x, title: x_title), else: vl
    vl = if y_title = opts[:y], do: Vl.encode_field(vl, :y, title: y_title), else: vl
    vl
  end

  @doc """
  Formats a DateTime as HH:MM:SS for display.

  Used for time axis labels.
  """
  def format_time_tick(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0..7)
  end

  @doc """
  Converts data to VegaLite-compatible format.

  Ensures all data fields are JSON-serializable and properly formatted
  for VegaLite consumption.
  """
  def prepare_data(data) when is_list(data) do
    Enum.map(data, &prepare_data_point/1)
  end

  defp prepare_data_point(point) when is_map(point) do
    point
    |> Map.new(fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Creates a line chart layer for time series data.

  Returns a VegaLite layer with both line and point marks.

  ## Options

    * `:x_field` - Field name for X-axis (required)
    * `:y_field` - Field name for Y-axis (required)
    * `:colour_field` - Field name for colour encoding (optional)
    * `:stroke_width` - Line width (default: 2)
    * `:point_size` - Point size (default: 50)
  """
  def line_layer(vl, opts) do
    x_field = Keyword.fetch!(opts, :x_field)
    y_field = Keyword.fetch!(opts, :y_field)
    colour_field = Keyword.get(opts, :colour_field)
    stroke_width = Keyword.get(opts, :stroke_width, 2)
    point_size = Keyword.get(opts, :point_size, 50)

    base_encoding =
      if colour_field do
        Vl.encode_field(vl, :color, colour_field, type: :nominal)
      else
        vl
      end

    # Line mark
    line =
      base_encoding
      |> Vl.mark(:line, stroke_width: stroke_width, opacity: 0.7)
      |> Vl.encode_field(:x, x_field, type: :temporal)
      |> Vl.encode_field(:y, y_field, type: :quantitative)

    # Point mark
    point =
      base_encoding
      |> Vl.mark(:point, size: point_size, opacity: 0.8)
      |> Vl.encode_field(:x, x_field, type: :temporal)
      |> Vl.encode_field(:y, y_field, type: :quantitative)

    Vl.new()
    |> Vl.layers([line, point])
  end

  @doc """
  Creates a bar chart for histogram data.

  ## Options

    * `:x_field` - Field name for X-axis categories (required)
    * `:y_field` - Field name for Y-axis values (required)
    * `:colour_field` - Field name for colour encoding (optional)
    * `:colour_scale` - Custom colour scale (optional)
  """
  def bar_chart(vl, opts) do
    x_field = Keyword.fetch!(opts, :x_field)
    y_field = Keyword.fetch!(opts, :y_field)
    colour_field = Keyword.get(opts, :colour_field)
    colour_scale = Keyword.get(opts, :colour_scale)

    vl
    |> Vl.mark(:bar, opacity: 0.8)
    |> Vl.encode_field(:x, x_field, type: :ordinal)
    |> Vl.encode_field(:y, y_field, type: :quantitative)
    |> maybe_add_colour(colour_field, colour_scale)
  end

  defp maybe_add_colour(vl, nil, _), do: vl

  defp maybe_add_colour(vl, colour_field, nil) do
    Vl.encode_field(vl, :color, colour_field, type: :nominal)
  end

  defp maybe_add_colour(vl, colour_field, colour_scale) do
    Vl.encode_field(vl, :color, colour_field, type: :nominal, scale: colour_scale)
  end
end

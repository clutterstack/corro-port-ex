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
  Thresholds align with the 300/600/900ms batching cut-offs used elsewhere.
  """
  def time_offset_colour(avg_offset_ms) when is_number(avg_offset_ms) do
    cond do
      avg_offset_ms < 300 -> "#10B981"   # Very early - green
      avg_offset_ms < 600 -> "#F59E0B"   # Moderate offset - yellow
      avg_offset_ms < 900 -> "#F97316"   # Longer offset - orange
      true -> "#EF4444"                  # Very late - red
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

end

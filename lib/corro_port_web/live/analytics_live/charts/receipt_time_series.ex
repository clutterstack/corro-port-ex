defmodule CorroPortWeb.AnalyticsLive.Charts.ReceiptTimeSeries do
  @moduledoc """
  SVG time series chart rendering for message receipt times (propagation delays).

  Renders a line chart showing how propagation delays change over the course
  of an experiment, with separate lines for each receiving node. This complements
  the RTT chart by showing when messages actually arrived via gossip, rather than
  when acknowledgments were sent back.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.TickHelpers

  @doc """
  Renders an SVG time series plot showing propagation delay over time for each node.

  The chart includes:
  - Line plots for each node showing propagation delay progression
  - Data points as circles
  - X-axis with time offset labels (matching RTT chart)
  - Y-axis with propagation delay (ms) labels
  - Legend identifying each node's line by colour

  Returns a "No receipt data available" message if there are no data points.

  ## Parameters

    * `receipt_time_series` - List of series maps, each containing:
      * `:node_id` - Identifier for the receiving node
      * `:data_points` - List of point maps with `:send_time`, `:receipt_time`, `:propagation_delay_ms`
  """
  attr :receipt_time_series, :list, required: true

  def render_receipt_time_series(assigns) do
    receipt_time_series = assigns.receipt_time_series
    all_points = Enum.flat_map(receipt_time_series, & &1.data_points)

    if all_points == [] do
      ~H"""
      <div class="text-base-content/50 text-center py-8">
        No receipt time data available
      </div>
      """
    else
      chart_height = 400
      chart_width = 900
      padding = %{top: 20, right: 120, bottom: 60, left: 60}

      plot_width = chart_width - padding.left - padding.right
      plot_height = chart_height - padding.top - padding.bottom

      # Calculate time range (using send_time for X-axis, same as RTT chart)
      all_times = Enum.map(all_points, & &1.send_time)
      min_time = Enum.min(all_times, DateTime)
      max_time = Enum.max(all_times, DateTime)
      time_range_ms = DateTime.diff(max_time, min_time, :millisecond)

      # Calculate propagation delay range
      all_delays = Enum.map(all_points, & &1.propagation_delay_ms)
      min_delay = Enum.min(all_delays)
      max_delay = Enum.max(all_delays)
      delay_range = max_delay - min_delay

      # Add 10% padding to delay range for better visualization
      delay_padding = max(delay_range * 0.1, 10)
      plot_min_delay = max(0, min_delay - delay_padding)
      plot_max_delay = max_delay + delay_padding

      # Node colours - cycle through a palette (same as RTT chart)
      node_colours = [
        "#3B82F6",
        "#10B981",
        "#F59E0B",
        "#EF4444",
        "#8B5CF6",
        "#EC4899",
        "#14B8A6",
        "#F97316"
      ]

      # Generate nice round tick marks
      y_ticks = TickHelpers.generate_ticks(plot_min_delay, plot_max_delay, 6)
      x_ticks = TickHelpers.generate_time_ticks(time_range_ms, 5)

      assigns = %{
        chart_width: chart_width,
        chart_height: chart_height,
        padding: padding,
        plot_width: plot_width,
        plot_height: plot_height,
        receipt_time_series: receipt_time_series,
        min_time: min_time,
        max_time: max_time,
        time_range_ms: time_range_ms,
        plot_min_delay: plot_min_delay,
        plot_max_delay: plot_max_delay,
        delay_range: plot_max_delay - plot_min_delay,
        node_colours: node_colours,
        y_ticks: y_ticks,
        x_ticks: x_ticks
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
        <text x="20" y={@padding.top + @plot_height / 2} text-anchor="middle" transform={"rotate(-90, 20, #{@padding.top + @plot_height / 2})"} class="text-sm fill-gray-600">
          Propagation Delay (ms)
        </text>

        <!-- X-axis label -->
        <text x={@padding.left + @plot_width / 2} y={@chart_height - 5} text-anchor="middle" class="text-sm fill-gray-600">
          Time Offset (ms)
        </text>

        <!-- Y-axis ticks -->
        <%= for {value, position} <- @y_ticks do %>
          <% y = @chart_height - @padding.bottom - (@plot_height * position) %>
          <line x1={@padding.left - 5} y1={y} x2={@padding.left} y2={y} stroke="#9CA3AF" stroke-width="1" />
          <text x={@padding.left - 10} y={y + 4} text-anchor="end" class="text-xs fill-gray-600">
            {value}
          </text>
        <% end %>

        <!-- X-axis ticks (relative time in ms) -->
        <%= for {value, position} <- @x_ticks do %>
          <% x = @padding.left + (@plot_width * position) %>
          <line x1={x} y1={@chart_height - @padding.bottom} y2={@chart_height - @padding.bottom + 5} stroke="#9CA3AF" stroke-width="1" />
          <text x={x} y={@chart_height - @padding.bottom + 20} text-anchor="middle" class="text-xs fill-gray-600">
            +{value}
          </text>
        <% end %>

        <!-- Plot data for each node -->
        <%= for {series, series_index} <- Enum.with_index(@receipt_time_series) do %>
          <% colour = Enum.at(@node_colours, rem(series_index, length(@node_colours))) %>

          <!-- Points and connecting lines -->
          <%= if length(series.data_points) > 1 do %>
            <% path_data = build_line_path(
              series.data_points,
              @min_time,
              @time_range_ms,
              @plot_min_delay,
              @delay_range,
              @padding,
              @plot_width,
              @plot_height
            ) %>
            <path d={path_data} fill="none" stroke={colour} stroke-width="2" opacity="0.7" />
          <% end %>

          <!-- Data points -->
          <%= for point <- series.data_points do %>
            <% x = calculate_x_position(point.send_time, @min_time, @time_range_ms, @padding.left, @plot_width) %>
            <% y = calculate_y_position(point.propagation_delay_ms, @plot_min_delay, @delay_range, @chart_height, @padding.bottom, @plot_height) %>
            <circle cx={x} cy={y} r="3" fill={colour} opacity="0.8" />
          <% end %>
        <% end %>

        <!-- Legend -->
        <%= for {series, series_index} <- Enum.with_index(@receipt_time_series) do %>
          <% colour = Enum.at(@node_colours, rem(series_index, length(@node_colours))) %>
          <% legend_y = @padding.top + 20 + (series_index * 20) %>
          <circle cx={@chart_width - @padding.right + 15} cy={legend_y} r="4" fill={colour} />
          <text x={@chart_width - @padding.right + 25} y={legend_y + 4} class="text-xs fill-gray-700">
            {series.node_id}
          </text>
        <% end %>
      </svg>
      """
    end
  end

  @doc """
  Calculates the X position for a given timestamp within the plot area.

  Maps the timestamp onto the plot width based on the time range in milliseconds.
  Returns the centre position if time_range_ms is 0.
  """
  def calculate_x_position(time, min_time, time_range_ms, left_padding, plot_width) do
    if time_range_ms > 0 do
      time_offset_ms = DateTime.diff(time, min_time, :millisecond)
      left_padding + time_offset_ms / time_range_ms * plot_width
    else
      left_padding + plot_width / 2
    end
  end

  @doc """
  Calculates the Y position for a given propagation delay value within the plot area.

  Maps the delay value onto the plot height based on the delay range.
  Y coordinates are inverted (higher values = lower on screen).
  Returns the centre position if delay_range is 0.
  """
  def calculate_y_position(
        delay_ms,
        plot_min_delay,
        delay_range,
        chart_height,
        bottom_padding,
        plot_height
      ) do
    if delay_range > 0 do
      normalized = (delay_ms - plot_min_delay) / delay_range
      chart_height - bottom_padding - normalized * plot_height
    else
      chart_height - bottom_padding - plot_height / 2
    end
  end

  @doc """
  Builds an SVG path string connecting all data points in a series.

  Creates a path that moves to the first point (M) and then draws lines
  to each subsequent point (L).
  """
  def build_line_path(
        data_points,
        min_time,
        time_range_ms,
        plot_min_delay,
        delay_range,
        padding,
        plot_width,
        plot_height
      ) do
    chart_height = padding.top + plot_height + padding.bottom

    data_points
    |> Enum.map(fn point ->
      x =
        calculate_x_position(point.send_time, min_time, time_range_ms, padding.left, plot_width)

      y =
        calculate_y_position(
          point.propagation_delay_ms,
          plot_min_delay,
          delay_range,
          chart_height,
          padding.bottom,
          plot_height
        )

      {x, y}
    end)
    |> Enum.with_index()
    |> Enum.map(fn {{x, y}, index} ->
      if index == 0 do
        "M #{x} #{y}"
      else
        "L #{x} #{y}"
      end
    end)
    |> Enum.join(" ")
  end
end

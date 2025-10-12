defmodule CorroPortWeb.AnalyticsLive.Charts.TimeSeries do
  @moduledoc """
  SVG time series chart rendering for RTT over time.

  Renders a line chart showing how round-trip times change over the course
  of an experiment, with separate lines for each responding node.
  """

  use Phoenix.Component

  @doc """
  Renders an SVG time series plot showing RTT over time for each node.

  The chart includes:
  - Line plots for each node showing RTT progression
  - Data points as circles
  - X-axis with time labels
  - Y-axis with RTT (ms) labels
  - Legend identifying each node's line by colour

  Returns a "No RTT data available" message if there are no data points.

  ## Parameters

    * `rtt_time_series` - List of series maps, each containing:
      * `:node_id` - Identifier for the responding node
      * `:data_points` - List of point maps with `:send_time` and `:rtt_ms`
  """
  attr :rtt_time_series, :list, required: true
  def render_rtt_time_series(assigns) do
    rtt_time_series = assigns.rtt_time_series
    all_points = Enum.flat_map(rtt_time_series, & &1.data_points)
  # def render_rtt_time_series(rtt_time_series) do
    # Extract all data points to determine ranges
    # all_points =
    #   rtt_time_series
    #   |> Enum.flat_map(fn series -> series.data_points end)

    if all_points == [] do
      # assigns = %{}

      ~H"""
      <div class="text-base-content/50 text-center py-8">
        No RTT data available
      </div>
      """
    else
      chart_height = 400
      chart_width = 900
      padding = %{top: 20, right: 120, bottom: 60, left: 60}

      plot_width = chart_width - padding.left - padding.right
      plot_height = chart_height - padding.top - padding.bottom

      # Calculate time range
      all_times = Enum.map(all_points, & &1.send_time)
      min_time = Enum.min(all_times, DateTime)
      max_time = Enum.max(all_times, DateTime)
      time_range_ms = DateTime.diff(max_time, min_time, :millisecond)

      # Calculate RTT range
      all_rtts = Enum.map(all_points, & &1.rtt_ms)
      min_rtt = Enum.min(all_rtts)
      max_rtt = Enum.max(all_rtts)
      rtt_range = max_rtt - min_rtt

      # Add 10% padding to RTT range for better visualization
      rtt_padding = max(rtt_range * 0.1, 10)
      plot_min_rtt = max(0, min_rtt - rtt_padding)
      plot_max_rtt = max_rtt + rtt_padding

      # Node colours - cycle through a palette
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

      assigns = %{
        chart_width: chart_width,
        chart_height: chart_height,
        padding: padding,
        plot_width: plot_width,
        plot_height: plot_height,
        rtt_time_series: rtt_time_series,
        min_time: min_time,
        max_time: max_time,
        time_range_ms: time_range_ms,
        plot_min_rtt: plot_min_rtt,
        plot_max_rtt: plot_max_rtt,
        rtt_range: plot_max_rtt - plot_min_rtt,
        node_colours: node_colours
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
          RTT (ms)
        </text>

        <!-- X-axis label -->
        <text x={@padding.left + @plot_width / 2} y={@chart_height - 5} text-anchor="middle" class="text-sm fill-gray-600">
          Message Send Time
        </text>

        <!-- Y-axis ticks -->
        <%= for i <- 0..5 do %>
          <% y = @chart_height - @padding.bottom - (@plot_height * i / 5) %>
          <% value = Float.round(@plot_min_rtt + (@rtt_range * i / 5), 1) %>
          <line x1={@padding.left - 5} y1={y} x2={@padding.left} y2={y} stroke="#9CA3AF" stroke-width="1" />
          <text x={@padding.left - 10} y={y + 4} text-anchor="end" class="text-xs fill-gray-600">
            {value}
          </text>
        <% end %>

        <!-- X-axis ticks (time) -->
        <%= for i <- 0..4 do %>
          <% x = @padding.left + (@plot_width * i / 4) %>
          <% time_offset_ms = @time_range_ms * i / 4 %>
          <% tick_time = DateTime.add(@min_time, trunc(time_offset_ms), :millisecond) %>
          <line x1={x} y1={@chart_height - @padding.bottom} y2={@chart_height - @padding.bottom + 5} stroke="#9CA3AF" stroke-width="1" />
          <text x={x} y={@chart_height - @padding.bottom + 20} text-anchor="middle" class="text-xs fill-gray-600">
            {format_time_tick(tick_time)}
          </text>
        <% end %>

        <!-- Plot data for each node -->
        <%= for {series, series_index} <- Enum.with_index(@rtt_time_series) do %>
          <% colour = Enum.at(@node_colours, rem(series_index, length(@node_colours))) %>

          <!-- Points and connecting lines -->
          <%= if length(series.data_points) > 1 do %>
            <% path_data = build_line_path(
              series.data_points,
              @min_time,
              @time_range_ms,
              @plot_min_rtt,
              @rtt_range,
              @padding,
              @plot_width,
              @plot_height
            ) %>
            <path d={path_data} fill="none" stroke={colour} stroke-width="2" opacity="0.7" />
          <% end %>

          <!-- Data points -->
          <%= for point <- series.data_points do %>
            <% x = calculate_x_position(point.send_time, @min_time, @time_range_ms, @padding.left, @plot_width) %>
            <% y = calculate_y_position(point.rtt_ms, @plot_min_rtt, @rtt_range, @chart_height, @padding.bottom, @plot_height) %>
            <circle cx={x} cy={y} r="3" fill={colour} opacity="0.8" />
          <% end %>
        <% end %>

        <!-- Legend -->
        <%= for {series, series_index} <- Enum.with_index(@rtt_time_series) do %>
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
  Formats a DateTime for display on the X-axis as HH:MM:SS.
  """
  def format_time_tick(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0..7)
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
  Calculates the Y position for a given RTT value within the plot area.

  Maps the RTT value onto the plot height based on the RTT range.
  Y coordinates are inverted (higher values = lower on screen).
  Returns the centre position if rtt_range is 0.
  """
  def calculate_y_position(
        rtt_ms,
        plot_min_rtt,
        rtt_range,
        chart_height,
        bottom_padding,
        plot_height
      ) do
    if rtt_range > 0 do
      normalized = (rtt_ms - plot_min_rtt) / rtt_range
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
        plot_min_rtt,
        rtt_range,
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
          point.rtt_ms,
          plot_min_rtt,
          rtt_range,
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

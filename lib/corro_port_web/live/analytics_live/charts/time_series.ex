defmodule CorroPortWeb.AnalyticsLive.Charts.TimeSeries do
  @moduledoc """
  SVG time series chart rendering for RTT over time.

  Renders a line chart showing how round-trip acknowledgement times change
  over the course of an experiment, with separate lines for each responding node.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.TickHelpers

  @doc """
  Renders an SVG time series plot showing RTT over time for each node.

  The chart includes:
  - Line plots for RTT progression
  - Data points as circles
  - X-axis with time offset labels
  - Y-axis with latency (ms) labels
  - Legend identifying each node's line by colour

  Returns a message if there is no data available.

  ## Parameters

    * `rtt_time_series` - List of series maps for RTT data, each containing:
      * `:node_id` - Identifier for the responding node
      * `:data_points` - List of point maps with `:send_time` and `:rtt_ms`
    * `receipt_time_series` - Legacy parameter, no longer used (kept for API compatibility)
  """
  attr :rtt_time_series, :list, required: true
  attr :receipt_time_series, :list, default: []

  def render_rtt_time_series(assigns) do
    rtt_time_series = assigns.rtt_time_series
    receipt_time_series = assigns.receipt_time_series

    all_rtt_points = Enum.flat_map(rtt_time_series, & &1.data_points)
    all_receipt_points = Enum.flat_map(receipt_time_series, & &1.data_points)
    if all_rtt_points == [] and all_receipt_points == [] do
      ~H"""
      <div class="text-base-content/50 text-center py-8">
        No timing data available
      </div>
      """
    else
      chart_height = 400
      chart_width = 900
      padding = %{top: 20, right: 120, bottom: 80, left: 60}

      plot_width = chart_width - padding.left - padding.right
      plot_height = chart_height - padding.top - padding.bottom

      # Calculate time range from both datasets
      all_times =
        (Enum.map(all_rtt_points, & &1.send_time) ++
           Enum.map(all_receipt_points, & &1.send_time))
        |> Enum.reject(&is_nil/1)

      {min_time, max_time, time_range_ms} =
        if all_times != [] do
          min_t = Enum.min(all_times, DateTime)
          max_t = Enum.max(all_times, DateTime)
          {min_t, max_t, DateTime.diff(max_t, min_t, :millisecond)}
        else
          now = DateTime.utc_now()
          {now, now, 0}
        end

      # Calculate combined value range (both RTT and propagation delays)
      all_values =
        (Enum.map(all_rtt_points, & &1.rtt_ms) ++
           Enum.map(all_receipt_points, & &1.propagation_delay_ms))
        |> Enum.reject(&is_nil/1)

      {plot_min_value, plot_max_value} =
        if all_values != [] do
          min_val = Enum.min(all_values)
          max_val = Enum.max(all_values)
          value_range = max_val - min_val

          # Add 10% padding for better visualization
          value_padding = max(value_range * 0.1, 10)
          {max(0, min_val - value_padding), max_val + value_padding}
        else
          {0, 100}
        end

      value_range = plot_max_value - plot_min_value

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

      # Generate nice round tick marks
      y_ticks = TickHelpers.generate_ticks(plot_min_value, plot_max_value, 6)
      x_ticks = TickHelpers.generate_time_ticks(time_range_ms, 5)

      assigns = %{
        chart_width: chart_width,
        chart_height: chart_height,
        padding: padding,
        plot_width: plot_width,
        plot_height: plot_height,
        rtt_time_series: rtt_time_series,
        receipt_time_series: receipt_time_series,
        min_time: min_time,
        max_time: max_time,
        time_range_ms: time_range_ms,
        plot_min_value: plot_min_value,
        plot_max_value: plot_max_value,
        value_range: value_range,
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
          Latency (ms)
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

        <!-- Plot RTT data (solid lines) -->
        <%= for {series, series_index} <- Enum.with_index(@rtt_time_series) do %>
          <% colour = Enum.at(@node_colours, rem(series_index, length(@node_colours))) %>

          <!-- RTT connecting lines (solid) -->
          <%= if length(series.data_points) > 1 do %>
            <% path_data = build_rtt_line_path(
              series.data_points,
              @min_time,
              @time_range_ms,
              @plot_min_value,
              @value_range,
              @padding,
              @plot_width,
              @plot_height
            ) %>
            <path d={path_data} fill="none" stroke={colour} stroke-width="2" opacity="0.7" />
          <% end %>

          <!-- RTT data points -->
          <%= for point <- series.data_points do %>
            <% x = calculate_x_position(point.send_time, @min_time, @time_range_ms, @padding.left, @plot_width) %>
            <% y = calculate_y_position(point.rtt_ms, @plot_min_value, @value_range, @chart_height, @padding.bottom, @plot_height) %>
            <circle cx={x} cy={y} r="3" fill={colour} opacity="0.8" />
          <% end %>
        <% end %>


        <!-- Legend -->
        <% all_nodes = (@rtt_time_series ++ @receipt_time_series) |> Enum.map(& &1.node_id) |> Enum.uniq() %>
        <%= for {node_id, node_index} <- Enum.with_index(all_nodes) do %>
          <% colour = Enum.at(@node_colours, rem(node_index, length(@node_colours))) %>
          <% legend_y = @padding.top + 20 + (node_index * 20) %>
          <circle cx={@chart_width - @padding.right + 15} cy={legend_y} r="4" fill={colour} />
          <text x={@chart_width - @padding.right + 25} y={legend_y + 4} class="text-xs fill-gray-700">
            {node_id}
          </text>
        <% end %>

        <!-- Legend explanation at bottom -->
        <text x={@padding.left} y={@chart_height - 30} class="text-xs fill-gray-600">
          Showing RTT (round-trip time) for each node
        </text>
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
  Calculates the Y position for a given value within the plot area.

  Maps the value onto the plot height based on the value range.
  Y coordinates are inverted (higher values = lower on screen).
  Returns the centre position if value_range is 0.
  """
  def calculate_y_position(
        value,
        plot_min_value,
        value_range,
        chart_height,
        bottom_padding,
        plot_height
      ) do
    if value_range > 0 do
      normalized = (value - plot_min_value) / value_range
      chart_height - bottom_padding - normalized * plot_height
    else
      chart_height - bottom_padding - plot_height / 2
    end
  end

  @doc """
  Builds an SVG path string connecting RTT data points.
  """
  def build_rtt_line_path(
        data_points,
        min_time,
        time_range_ms,
        plot_min_value,
        value_range,
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
          plot_min_value,
          value_range,
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

  @doc """
  Builds an SVG path string connecting receipt time (propagation delay) data points.
  """
  def build_receipt_line_path(
        data_points,
        min_time,
        time_range_ms,
        plot_min_value,
        value_range,
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
          plot_min_value,
          value_range,
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

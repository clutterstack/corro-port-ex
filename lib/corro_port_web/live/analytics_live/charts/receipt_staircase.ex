defmodule CorroPortWeb.AnalyticsLive.Charts.ReceiptStaircase do
  @moduledoc """
  Compact bar chart showing message receipt patterns.

  Visualises message receipt times as a bar graph where:
  - X-axis shows message index (1, 2, 3, ...)
  - Y-axis shows time since experiment start (milliseconds from first message send)
  - Bar height represents when each message was received at the remote node
  - Messages arriving together (batching) will have similar bar heights

  The batching pattern becomes visually obvious when multiple consecutive bars
  have the same or very similar heights, showing that Corrosion delivered them
  together via gossip.

  Designed to be compact (60-80px per node) so many nodes can be displayed simultaneously.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.TickHelpers

  @doc """
  Renders a compact receipt time chart for a single node's receipt pattern.

  ## Parameters

    * `node_id` - The receiving node identifier
    * `delays` - List of time offsets from experiment start in temporal order (milliseconds)
    * `stats` - Statistics map containing min/max/avg/median/p95 values
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
      chart_height = 70
      chart_width = 800
      padding = %{top: 10, right: 10, bottom: 25, left: 50}

      plot_width = chart_width - padding.left - padding.right
      plot_height = chart_height - padding.top - padding.bottom

      message_count = length(time_offsets)
      min_offset = stats.min_delay_ms  # Field name kept for compatibility
      max_offset = stats.max_delay_ms
      offset_range = max_offset - min_offset

      # Add 10% padding to Y-axis
      y_padding = max(offset_range * 0.1, 5)
      plot_min_offset = max(0, min_offset - y_padding)
      plot_max_offset = max_offset + y_padding
      plot_offset_range = plot_max_offset - plot_min_offset

      # Generate Y-axis ticks (3-4 ticks for compact chart)
      y_ticks = TickHelpers.generate_ticks(plot_min_offset, plot_max_offset, 3)

      # Colour based on average time offset (earlier = green, later = red)
      line_colour = time_offset_to_colour(stats.avg_delay_ms)

      assigns =
        Map.merge(assigns, %{
          chart_height: chart_height,
          chart_width: chart_width,
          padding: padding,
          plot_width: plot_width,
          plot_height: plot_height,
          message_count: message_count,
          time_offsets: time_offsets,
          plot_min_offset: plot_min_offset,
          plot_max_offset: plot_max_offset,
          plot_offset_range: plot_offset_range,
          y_ticks: y_ticks,
          line_colour: line_colour
        })

      ~H"""
      <div class="mb-3 p-3 bg-base-300 rounded-lg">
        <!-- Node header with summary stats -->
        <div class="flex items-center justify-between mb-2">
          <span class="font-mono font-medium text-sm">{@node_id}</span>
          <span class="text-xs text-base-content/70">
            {@message_count} msgs · {@stats.avg_delay_ms}ms avg · {@stats.median_delay_ms}ms median
          </span>
        </div>

        <!-- SVG staircase chart -->
        <svg
          width="100%"
          height="100%"
          viewBox={"0 0 #{@chart_width} #{@chart_height}"}
          class="border border-base-content/10 rounded bg-base-100"
        >
          <!-- Y-axis -->
          <line
            x1={@padding.left}
            y1={@padding.top}
            x2={@padding.left}
            y2={@chart_height - @padding.bottom}
            stroke="currentColor"
            stroke-width="1"
            class="stroke-base-content/30"
          />

          <!-- X-axis -->
          <line
            x1={@padding.left}
            y1={@chart_height - @padding.bottom}
            x2={@chart_width - @padding.right}
            y2={@chart_height - @padding.bottom}
            stroke="currentColor"
            stroke-width="1"
            class="stroke-base-content/30"
          />

          <!-- Y-axis ticks and labels -->
          <%= for {value, position} <- @y_ticks do %>
            <% y = @chart_height - @padding.bottom - (@plot_height * position) %>
            <line
              x1={@padding.left - 3}
              y1={y}
              x2={@padding.left}
              y2={y}
              stroke="currentColor"
              stroke-width="1"
              class="stroke-base-content/30"
            />
            <text x={@padding.left - 6} y={y + 3} text-anchor="end" class="text-xs fill-base-content/70">
              {value}
            </text>
          <% end %>

          <!-- Y-axis label -->
          <text
            x="12"
            y={@padding.top + @plot_height / 2}
            text-anchor="middle"
            transform={"rotate(-90, 12, #{@padding.top + @plot_height / 2})"}
            class="text-xs fill-base-content/70"
          >
            Time (ms)
          </text>

          <!-- X-axis ticks (show first, middle, last message indices) -->
          <% x_tick_indices = get_x_tick_indices(@message_count) %>
          <%= for msg_index <- x_tick_indices do %>
            <% x = @padding.left + (msg_index - 1) / (@message_count - 1) * @plot_width %>
            <line
              x1={x}
              y1={@chart_height - @padding.bottom}
              y2={@chart_height - @padding.bottom + 3}
              stroke="currentColor"
              stroke-width="1"
              class="stroke-base-content/30"
            />
            <text x={x} y={@chart_height - @padding.bottom + 14} text-anchor="middle" class="text-xs fill-base-content/70">
              {msg_index}
            </text>
          <% end %>

          <!-- X-axis label -->
          <text
            x={@padding.left + @plot_width / 2}
            y={@chart_height - 3}
            text-anchor="middle"
            class="text-xs fill-base-content/70"
          >
            Message Index
          </text>

          <!-- Receipt time bars -->
          <%= for {time_offset, index} <- Enum.with_index(@time_offsets) do %>
            <%
              x = calculate_x_for_index(index, @message_count, @padding.left, @plot_width)
              y = calculate_y_for_time_offset(time_offset, @plot_min_offset, @plot_offset_range, @chart_height, @padding.bottom, @plot_height)
              baseline_y = @chart_height - @padding.bottom
              bar_height = baseline_y - y
              # Calculate bar width with small gap between bars
              bar_width = if @message_count > 1 do
                (@plot_width / @message_count) * 0.9
              else
                @plot_width * 0.5
              end
              # Center the bar on the x position
              bar_x = x - (bar_width / 2)
            %>
            <rect
              x={bar_x}
              y={y}
              width={bar_width}
              height={bar_height}
              fill={@line_colour}
              opacity="0.8"
              stroke={@line_colour}
              stroke-width="1"
            >
              <title>Msg {index + 1}: +{time_offset}ms from start</title>
            </rect>
          <% end %>
        </svg>
      </div>
      """
    end
  end

  # Helper functions

  @doc """
  Calculates X position for a message index (0-based).
  """
  def calculate_x_for_index(index, message_count, left_padding, plot_width) do
    if message_count > 1 do
      left_padding + index / (message_count - 1) * plot_width
    else
      left_padding + plot_width / 2
    end
  end

  @doc """
  Calculates Y position for a time offset value.
  Y coordinates are inverted (higher values = lower on screen).
  """
  def calculate_y_for_time_offset(
        time_offset,
        plot_min_offset,
        plot_offset_range,
        chart_height,
        bottom_padding,
        plot_height
      ) do
    if plot_offset_range > 0 do
      normalized = (time_offset - plot_min_offset) / plot_offset_range
      chart_height - bottom_padding - normalized * plot_height
    else
      chart_height - bottom_padding - plot_height / 2
    end
  end

  @doc """
  Determines which message indices to show as X-axis ticks.
  Shows first, last, and a few in between for compact display.
  """
  def get_x_tick_indices(message_count) when message_count <= 5 do
    # For small counts, show all
    Enum.to_list(1..message_count)
  end

  def get_x_tick_indices(message_count) do
    # Show first, middle, last (and maybe quartiles for larger datasets)
    middle = div(message_count, 2) + 1

    if message_count <= 20 do
      [1, middle, message_count]
    else
      q1 = div(message_count, 4) + 1
      q3 = div(message_count * 3, 4) + 1
      [1, q1, middle, q3, message_count]
    end
  end

  # Selects a colour based on average time offset (earlier = green, later = red)
  defp time_offset_to_colour(avg_offset_ms) when is_number(avg_offset_ms) do
    # For time offsets, earlier arrivals are better (green) and later are worse (red)
    # Adjust thresholds based on typical experiment duration
    cond do
      avg_offset_ms < 100 -> "#10B981"   # Very early - green
      avg_offset_ms < 500 -> "#F59E0B"   # Medium time - yellow
      avg_offset_ms < 2000 -> "#F97316"  # Later - orange
      true -> "#EF4444"                   # Very late - red
    end
  end

  defp time_offset_to_colour(_), do: "#9CA3AF"
end

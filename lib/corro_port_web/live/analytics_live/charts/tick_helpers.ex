defmodule CorroPortWeb.AnalyticsLive.Charts.TickHelpers do
  @moduledoc """
  Helper functions for generating nice round numbers for chart axis tick marks.
  """

  @doc """
  Generates a list of nice round tick values for an axis.

  Returns a list of {value, position_fraction} tuples where:
  - value: The nice round number to display
  - position_fraction: Where to place it (0.0 to 1.0) along the axis

  ## Examples

      iex> generate_ticks(0, 100, 5)
      [{0, 0.0}, {25, 0.25}, {50, 0.5}, {75, 0.75}, {100, 1.0}]

      iex> generate_ticks(0, 873, 5)
      [{0, 0.0}, {200, 0.229...}, {400, 0.458...}, {600, 0.687...}, {800, 0.916...}]
  """
  def generate_ticks(min_value, max_value, num_ticks) do
    range = max_value - min_value

    # Handle edge case where range is 0
    if range <= 0 do
      [{Float.round(min_value / 1, 1), 0.5}]
    else
      # Calculate ideal tick interval
      ideal_interval = range / (num_ticks - 1)
      nice_interval = nice_number(ideal_interval, false)

      # Calculate nice min and max that encompass the data
      nice_min = (min_value / nice_interval) |> Float.floor() |> Kernel.*(nice_interval)
      nice_max = (max_value / nice_interval) |> Float.ceil() |> Kernel.*(nice_interval)

      # Generate tick values
      nice_min
      |> Stream.iterate(&(&1 + nice_interval))
      |> Enum.take_while(&(&1 <= nice_max))
      |> Enum.map(fn tick_value ->
        # Calculate position as fraction of actual data range
        position = if range > 0, do: (tick_value - min_value) / range, else: 0.5

        # Format the value nicely
        formatted_value =
          if nice_interval >= 1 do
            round(tick_value)
          else
            Float.round(tick_value / 1, 1)
          end

        {formatted_value, position}
      end)
    end
  end

  @doc """
  Finds a "nice" number approximately equal to the given value.

  Nice numbers are 1, 2, 5, 10, 20, 50, 100, etc.

  If round is true, rounds to nearest nice number.
  If round is false, finds next nice number >= value.
  """
  defp nice_number(value, round) do
    exponent = :math.log10(value) |> Float.floor()
    fraction = value / :math.pow(10, exponent)

    nice_fraction =
      if round do
        cond do
          fraction < 1.5 -> 1
          fraction < 3 -> 2
          fraction < 7 -> 5
          true -> 10
        end
      else
        cond do
          fraction <= 1 -> 1
          fraction <= 2 -> 2
          fraction <= 5 -> 5
          true -> 10
        end
      end

    nice_fraction * :math.pow(10, exponent)
  end

  @doc """
  Generates nice round tick values for time offsets in milliseconds.

  Prefers round numbers like 0, 500, 1000, 2000, 5000, etc.
  """
  def generate_time_ticks(time_range_ms, num_ticks \\ 5) do
    generate_ticks(0, time_range_ms, num_ticks)
  end
end

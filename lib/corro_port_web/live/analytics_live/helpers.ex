defmodule CorroPortWeb.AnalyticsLive.Helpers do
  @moduledoc """
  Helper functions for formatting and display logic in AnalyticsLive.

  Provides:
  - Timestamp and duration formatting
  - Percentage display formatting
  - CSS class selection for latency indicators
  - Refresh scheduling
  """

  @doc """
  Formats a percentage value for display.

  ## Examples

      iex> format_percentage(42.5)
      "42.5%"

      iex> format_percentage(100.0)
      "100%"

      iex> format_percentage(nil)
      "0%"
  """
  def format_percentage(nil), do: "0%"

  def format_percentage(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
    |> Kernel.<>("%")
  end

  def format_percentage(value) when is_integer(value) do
    "#{value}%"
  end

  @doc """
  Formats a DateTime or NaiveDateTime for display.

  Returns "-" for nil values.
  """
  def format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  def format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end

  def format_datetime(nil), do: "-"
  def format_datetime(other), do: to_string(other)

  @doc """
  Formats a DateTime to show only the time portion.

  Returns "-" for nil or non-DateTime values.
  """
  def format_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_time()
    |> Time.to_string()
  end

  def format_time(_), do: "-"

  @doc """
  Calculates duration in seconds from a time range map.

  Returns nil if the time range is nil or incomplete.

  ## Examples

      iex> start = ~U[2025-01-01 10:00:00Z]
      iex> end_time = ~U[2025-01-01 10:05:00Z]
      iex> calculate_duration(%{start: start, end: end_time})
      300
  """
  def calculate_duration(nil), do: nil

  def calculate_duration(%{start: start_time, end: end_time}) do
    DateTime.diff(end_time, start_time, :second)
  end

  @doc """
  Returns a Tailwind CSS class for colour-coding latency values.

  - < 300ms: green (excellent)
  - 300-600ms: yellow (good)
  - 600-900ms: orange (fair)
  - >= 900ms: red (slow)

  ## Examples

      iex> latency_colour_class(150)
      "text-green-600 font-medium"

      iex> latency_colour_class(450)
      "text-yellow-600 font-medium"
  """
  def latency_colour_class(latency_ms) when is_number(latency_ms) do
    cond do
      latency_ms < 300 -> "text-green-600 font-medium"
      latency_ms < 600 -> "text-yellow-600 font-medium"
      latency_ms < 900 -> "text-orange-600 font-medium"
      true -> "text-red-600 font-medium"
    end
  end

  def latency_colour_class(_), do: "text-gray-600"

  @doc """
  Schedules a refresh message to be sent to the current process.

  Defaults to 5000ms if no interval is provided.
  """
  def schedule_refresh(interval \\ nil) do
    interval = interval || 5000
    Process.send_after(self(), :refresh, interval)
  end
end

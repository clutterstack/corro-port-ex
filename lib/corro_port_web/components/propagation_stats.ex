defmodule CorroPortWeb.PropagationStats do
  use Phoenix.Component

  @doc """
  Renders summary statistics in a responsive grid layout.
  """
  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true
  attr :expected_regions, :list, required: true
  attr :active_regions, :list, required: true
  attr :ack_regions, :list, required: true

  def propagation_stats(assigns) do
    stats = build_stats(assigns)
    assigns = assign(assigns, :stats, stats)

    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <.stat_card
        title="Expected Nodes"
        value={@stats.expected_count}
        description="{length(@expected_regions)} regions"
        error={@stats.expected_error}
      />

      <.stat_card
        title="Active Members"
        value={@stats.active_count}
        description="{length(@active_regions)} regions"
        error={@stats.active_error}
      />

      <.stat_card
        title="Acknowledged"
        value={length(@ack_regions)}
        description="regions responded"
        error={false}
      />

      <.stat_card
        title="Coverage"
        value="{@stats.coverage_percentage}%"
        description="acknowledgment rate"
        error={false}
      />
    </div>
    """
  end

  # Individual stat card component
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :description, :string, required: true
  attr :error, :boolean, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="stat bg-base-200 rounded-lg">
      <div class="stat-title">{@title}</div>
      <div class="stat-value text-2xl flex items-center">
        <%= if @error do %>
          <span class="text-error">?</span>
        <% else %>
          {@value}
        <% end %>
      </div>
      <div class="stat-desc">{@description}</div>
    </div>
    """
  end

  # Helper function to build all stats
  defp build_stats(assigns) do
    expected_count = get_count_or_error(assigns.expected_data, :nodes)
    active_count = get_count_or_error(assigns.active_data, :members)

    coverage_percentage =
      if expected_count != :error and length(assigns.expected_regions) > 0 do
        round(length(assigns.ack_regions) / length(assigns.expected_regions) * 100)
      else
        0
      end

    %{
      expected_count: expected_count,
      expected_error: expected_count == :error,
      active_count: active_count,
      active_error: active_count == :error,
      coverage_percentage: coverage_percentage
    }
  end

  defp get_count_or_error(data, key) do
    case Map.get(data, key) do
      {:ok, list} when is_list(list) -> length(list)
      {:error, _} -> :error
      _ -> 0
    end
  end
end

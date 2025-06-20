defmodule CorroPortWeb.PropagationProgress do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders real-time acknowledgment progress bar and region legend.
  """
  attr :expected_regions, :list, required: true
  attr :active_regions, :list, required: true
  attr :ack_regions, :list, required: true
  attr :our_regions, :list, required: true

  def propagation_progress(assigns) do
    ~H"""
    <div class="space-y-4">
      <!-- Real-time acknowledgment progress -->
      <.progress_bar
        ack_regions={@ack_regions}
        expected_regions={@expected_regions}
      />

      <!-- Region legend -->
      <.region_legend
        our_regions={@our_regions}
        active_regions={@active_regions}
        expected_regions={@expected_regions}
        ack_regions={@ack_regions}
      />
    </div>
    """
  end

  # Progress bar component
  attr :ack_regions, :list, required: true
  attr :expected_regions, :list, required: true

  defp progress_bar(assigns) do
    progress_percentage = calculate_progress_percentage(assigns.ack_regions, assigns.expected_regions)

    assigns = assign(assigns, :progress_percentage, progress_percentage)

    ~H"""
    <div class="mb-4">
      <div class="flex items-center justify-between text-sm mb-2">
        <span>Acknowledgment Progress:</span>
        <div class="flex items-center gap-2 text-sm">
          <span class="badge badge-success badge-sm">
            {length(@ack_regions)} acknowledged
          </span>
          <span class="badge badge-warning badge-sm">
            {length(@expected_regions)} expected
          </span>
        </div>
      </div>
      <div class="w-full bg-base-300 rounded-full h-2">
        <div
          class="h-2 rounded-full bg-gradient-to-r from-orange-500 to-violet-500 transition-all duration-500"
          style={"width: #{@progress_percentage}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  # Region legend component
  attr :our_regions, :list, required: true
  attr :active_regions, :list, required: true
  attr :expected_regions, :list, required: true
  attr :ack_regions, :list, required: true

  defp region_legend(assigns) do
    ~H"""
    <div class="text-sm text-base-content/70 space-y-2">
      <.legend_item
        color="#77b5fe"
        label="Our node"
        regions={@our_regions}
        empty_message="(region unknown)"
      />

      <.legend_item
        color="#ffdc66"
        label="Active nodes (CLI)"
        regions={@active_regions}
        empty_message="(none found)"
      />

      <.legend_item
        color="#ff8c42"
        label="Nodes from DNS"
        regions={@expected_regions}
        empty_message={dns_empty_message()}
      />

      <.legend_item
        color="#9d4edd"
        label="Acknowledged latest message"
        regions={@ack_regions}
        empty_message="(none yet)"
      />
    </div>
    """
  end

  # Individual legend item
  attr :color, :string, required: true
  attr :label, :string, required: true
  attr :regions, :list, required: true
  attr :empty_message, :string, required: true

  defp legend_item(assigns) do
    region_display = format_regions_display(assigns.regions, assigns.empty_message)
    assigns = assign(assigns, :region_display, region_display)

    ~H"""
    <div class="flex items-center">
      <span class="inline-block w-3 h-3 rounded-full mr-2" style={"background-color: #{@color};"}></span>
      {@label}
      {@region_display}
    </div>
    """
  end

  # Helper functions
  defp calculate_progress_percentage(ack_regions, expected_regions) do
    if length(expected_regions) > 0 do
      length(ack_regions) / length(expected_regions) * 100
    else
      0
    end
  end

  defp format_regions_display(regions, empty_message) do
    filtered_regions = Enum.reject(regions, &(&1 == "" or &1 == "unknown"))

    if filtered_regions != [] do
      " (#{Enum.join(filtered_regions, ", ")})"
    else
      " #{empty_message}"
    end
  end

  defp dns_empty_message do
    case Application.get_env(:corro_port, :node_config)[:environment] do
      :prod -> "(none found)"
      _ -> "(none; no DNS in dev)"
    end
  end
end

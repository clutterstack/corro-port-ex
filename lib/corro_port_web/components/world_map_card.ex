defmodule CorroPortWeb.WorldMapCard do
  use Phoenix.Component

  @doc """
  Renders a world map card with regions, acknowledgment progress, and legend.

  ## Attributes
  - `active_data` - Active member data from CLIMemberStore (contains regions and error state)
  - `our_regions` - List of our node's regions (blue animated markers)
  - `expected_regions` - List of expected regions from DNS (orange animated markers)
  - `ack_regions` - List of regions that acknowledged latest message (violet animated markers)
  - `show_acknowledgment_progress` - Whether to show the acknowledgment progress bar (default: false)
  """
  attr :active_data, :map, required: true
  attr :our_regions, :list, default: []
  attr :expected_regions, :list, default: []
  attr :ack_regions, :list, default: []
  attr :show_acknowledgment_progress, :boolean, default: false

  def world_map_card(assigns) do
    # Extract active regions from the same data source as CLI members table
    active_regions = get_active_regions_from_data(assigns.active_data, assigns.our_regions)
    cli_members_stale = has_cli_error?(assigns.active_data)
    
    assigns = assign(assigns, active_regions: active_regions, cli_members_stale: cli_members_stale)
    
    ~H"""
    <div class="card bg-base-100">
      <div class="card-body">
        <div class="rounded-lg border">
          <CorroPortWeb.WorldMap.world_map_svg
            regions={@active_regions}
            our_regions={@our_regions}
            expected_regions={@expected_regions}
            ack_regions={@ack_regions}
          />
        </div>

        <!-- Acknowledgment Progress (only shown when requested) -->
        <div :if={@show_acknowledgment_progress} class="mb-4">
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
              style={"width: #{calculate_progress_percentage(@expected_regions, @ack_regions)}%"}
            >
            </div>
          </div>
        </div>

        <!-- Legend -->
        <div class="text-sm text-base-content/70 space-y-2">
          <div class="flex items-center">
            <!-- Our node (blue with animation) -->
            <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #77b5fe;">
            </span>
            Our node
            {format_regions_display(@our_regions, "(region unknown)")}
          </div>

          <div class="flex items-center">
            <!-- Active nodes (yellow) -->
            <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ffdc66;">
            </span>
            Active nodes (CLI)
            {format_regions_display(@active_regions, "(none found)")}
            <span :if={@cli_members_stale} class="badge badge-warning badge-xs ml-2">stale</span>
          </div>

          <div class="flex items-center">
            <!-- Expected nodes from DNS (orange) -->
            <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #ff8c42;">
            </span>
            Nodes from DNS
            {dns_regions_display(@expected_regions)}
          </div>

          <div class="flex items-center">
            <!-- Acknowledged nodes (plasma violet) -->
            <span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: #9d4edd;">
            </span>
            Acknowledged latest message
            {format_regions_display(@ack_regions, "(none yet)")}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp calculate_progress_percentage(expected_regions, ack_regions) do
    if length(expected_regions) > 0 do
      length(ack_regions) / length(expected_regions) * 100
    else
      0
    end
  end

  defp format_regions_display(regions, empty_message) do
    filtered_regions = Enum.reject(regions, &(&1 == "" or &1 == "unknown"))

    if filtered_regions != [] do
      "(#{Enum.join(filtered_regions, ", ")})"
    else
      empty_message
    end
  end

  defp dns_regions_display(expected_regions) do
    case Application.get_env(:corro_port, :node_config)[:environment] do
      :prod ->
        format_regions_display(expected_regions, "(none found)")
      _ ->
        "(none; no DNS in dev)"
    end
  end

  # Extract active regions from the same data source as CLI members table
  defp get_active_regions_from_data(active_data, our_regions) do
    our_region = List.first(our_regions)
    
    # In development, don't exclude "dev" region since all nodes share it
    if our_region == "dev" do
      active_data.regions
    else
      # In production, exclude our region as usual
      Enum.reject(active_data.regions, &(&1 == our_region))
    end
  end

  # Check if CLI data has errors (same logic as CLI members table)
  defp has_cli_error?(active_data) do
    case active_data.members do
      {:error, _} -> true
      {:ok, _} -> active_data.cache_status.error != nil
    end
  end
end

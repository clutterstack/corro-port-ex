defmodule CorroPortWeb.PropagationHeader do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders the propagation page header with actions and error handling.
  """
  attr :expected_data, :map, required: true
  attr :active_data, :map, required: true

  def propagation_header(assigns) do
    ~H"""
    <.header>
      <.icon name="hero-radio" class="w-5 h-5 mr-2" /> DB change propagation
      <:subtitle>
        <div class="flex items-center gap-4">
          <span>Click "Send Message." Markers change colour as nodes confirm they've received the update.</span>
        </div>
      </:subtitle>
      <:actions>
        <div class="flex gap-2">
          <!-- Per-domain refresh buttons -->
          <.button
            phx-click="refresh_expected"
            class={refresh_button_class(@expected_data)}
          >
            <.icon name="hero-globe-alt" class="w-4 h-4 mr-1" />
            DNS
            <span :if={has_error?(@expected_data)} class="ml-1">⚠</span>
          </.button>

          <.button
            phx-click="refresh_active"
            class={refresh_button_class(@active_data)}
          >
            <.icon name="hero-command-line" class="w-4 h-4 mr-1" />
            CLI
            <span :if={has_error?(@active_data)} class="ml-1">⚠</span>
          </.button>

          <.button phx-click="reset_tracking" class="btn btn-warning btn-outline">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Reset Tracking
          </.button>

          <.button phx-click="send_message" variant="primary">
            <.icon name="hero-paper-airplane" class="w-4 h-4 mr-2" /> Send Message
          </.button>
        </div>
      </:actions>
    </.header>
    """
  end

  # Helper functions
  defp refresh_button_class(data) do
    base_classes = "btn btn-sm"
    if has_error?(data) do
      "#{base_classes} btn-error"
    else
      "#{base_classes} btn-outline"
    end
  end

  defp has_error?(data) do
    case Map.get(data, :nodes) || Map.get(data, :members) do
      {:error, _} -> true
      _ -> false
    end
  end
end

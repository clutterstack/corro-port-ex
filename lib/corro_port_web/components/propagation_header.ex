defmodule CorroPortWeb.PropagationHeader do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders the propagation page header with actions and error handling.
  """
  attr(:dns_data, :map, required: true)

  def propagation_header(assigns) do
    ~H"""
    <.header>
      DB change propagation
      <:subtitle>
        <div class="flex items-center gap-4">
          <span>
            Click "Send Message." Markers change colour as nodes confirm they've received the update.
          </span>
        </div>
      </:subtitle>
      <:actions>
        <div class="flex gap-2">
          <.button phx-click="reset_tracking" class="btn btn-warning btn-outline">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Reset Tracking
          </.button>

          <.button phx-click="test_pubsub" class="btn btn-secondary btn-outline">
            <.icon name="hero-signal" class="w-4 h-4 mr-2" /> Test Cluster PubSub
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
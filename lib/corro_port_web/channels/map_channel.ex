defmodule CorroPortWeb.MapChannel do
  @moduledoc """
  Phoenix Channel for real-time map updates.

  Currently minimal - supports connection but uses server-side rendering fallback.
  Future enhancement: broadcast marker state changes via PubSub integration.
  """
  use CorroPortWeb, :channel
  require Logger

  @impl true
  def join("map:" <> _map_id, _payload, socket) do
    Logger.debug("MapChannel: Client joined map channel")
    {:ok, socket}
  end

  @impl true
  def handle_in("state_sync", %{"client_state" => client_state}, socket) do
    Logger.debug("MapChannel: State sync requested: #{inspect(client_state)}")
    # Future: broadcast current marker state
    {:noreply, socket}
  end

  def handle_in(event, payload, socket) do
    Logger.warning("MapChannel: Unhandled event #{event}: #{inspect(payload)}")
    {:noreply, socket}
  end
end

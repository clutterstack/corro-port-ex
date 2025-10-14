defmodule CorroPortWeb.MapChannel do
  @moduledoc """
  Phoenix channel for real-time map marker updates.

  Handles real-time communication for FlyMapEx map components, enabling
  efficient marker updates, theme changes, and state synchronization
  without full LiveView rerenders.

  ## Channel Events

  ### Outbound (Server → Client)
  - `marker_state` - Initial complete map state
  - `marker_update` - Incremental marker group updates
  - `marker_add` - Add new markers to a group
  - `marker_remove` - Remove specific markers
  - `theme_change` - Map theme updates
  - `group_toggle` - Show/hide marker groups

  ### Inbound (Client → Server)
  - `state_sync` - Request full state synchronization
  - `ping` - Connection health check

  ## Message Format

      # Initial state
      %{
        event: "marker_state",
        marker_groups: [%{id: "prod", markers: [...], style: %{...}}],
        theme: %{land: "#fff", ocean: "#eee", ...},
        config: %{bbox: {0, 0, 800, 391}, ...}
      }

      # Incremental update
      %{
        event: "marker_update",
        group_id: "production",
        markers: [%{region: "sjc", coordinates: {37.4, -122.1}}]
      }

  ## Usage

      # In LiveView
      socket
      |> assign(:map_channel, "map:demo_room")
      |> push_event("map_state", %{marker_groups: groups})

      # Broadcast updates
      CorroPortWeb.Endpoint.broadcast("map:demo_room", "marker_update", update)
  """

  use CorroPortWeb, :channel

  require Logger

  @doc """
  Authorize channel join.

  For demo purposes, allows all joins. In production, you might verify
  user permissions or room access here.
  """
  @impl true
  def join("map:" <> _map_id, _payload, socket) do
    Logger.debug("MapChannel: Client joined")
    {:ok, socket}
  end

  @doc """
  Handle client state sync requests.

  Clients can request full state resync if they detect inconsistencies
  or after reconnecting from a network interruption.
  """
  @impl true
  def handle_in("state_sync", %{"client_state" => client_state}, socket) do
    Logger.debug("MapChannel: State sync requested", client_state: client_state)

    # Extract room ID from socket topic
    map_id = extract_map_id(socket.topic)

    # Get current server state (in real app, this would come from your state store)
    server_state = get_server_state(map_id)

    # Compare client and server states
    case compare_states(client_state, server_state) do
      :in_sync ->
        {:reply, {:ok, %{status: "in_sync"}}, socket}

      {:out_of_sync, diff} ->
        # Send full state update
        broadcast_marker_state(socket.topic, server_state)
        {:reply, {:ok, %{status: "state_updated", diff: diff}}, socket}

      {:error, reason} ->
        Logger.error("MapChannel: State sync error", reason: reason)
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{status: "pong"}}, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    Logger.warning("MapChannel: Unhandled event", event: event, payload: payload)
    {:noreply, socket}
  end

  @doc """
  Broadcast marker state to all subscribers.

  ## Examples

      CorroPortWeb.MapChannel.broadcast_marker_state("map:room1", %{
        marker_groups: [...],
        theme: %{...}
      })
  """
  def broadcast_marker_state(channel_topic, state) do
    CorroPortWeb.Endpoint.broadcast(channel_topic, "marker_state", state)
  end

  @doc """
  Broadcast incremental marker updates.

  ## Examples

      CorroPortWeb.MapChannel.broadcast_marker_update("map:room1", %{
        group_id: "production",
        markers: [%{region: "sjc", coordinates: {37.4, -122.1}}]
      })
  """
  def broadcast_marker_update(channel_topic, update) do
    CorroPortWeb.Endpoint.broadcast(channel_topic, "marker_update", update)
  end

  @doc """
  Broadcast theme changes.

  ## Examples

      CorroPortWeb.MapChannel.broadcast_theme_change("map:room1", %{
        theme: %{land: "#fff", ocean: "#eee"}
      })
  """
  def broadcast_theme_change(channel_topic, theme_data) do
    CorroPortWeb.Endpoint.broadcast(channel_topic, "theme_change", theme_data)
  end

  @doc """
  Broadcast marker group visibility toggles.

  ## Examples

      CorroPortWeb.MapChannel.broadcast_group_toggle("map:room1", %{
        group_id: "staging",
        visible: false
      })
  """
  def broadcast_group_toggle(channel_topic, toggle_data) do
    CorroPortWeb.Endpoint.broadcast(channel_topic, "group_toggle", toggle_data)
  end

  # Private helper functions for state management

  defp extract_map_id("map:" <> map_id), do: map_id
  defp extract_map_id(_), do: "default"

  defp get_server_state(map_id) do
    # In a real application, this would fetch from your state store
    # For now, return a mock state structure
    %{
      marker_groups: [],
      theme: %{},
      config: %{bbox: {0, 0, 800, 391}},
      last_update: System.system_time(:millisecond),
      map_id: map_id
    }
  end

  defp compare_states(client_state, server_state) do
    try do
      client_last_update = Map.get(client_state, "last_update", 0)
      server_last_update = Map.get(server_state, :last_update, 0)

      cond do
        client_last_update >= server_last_update ->
          :in_sync

        true ->
          diff = %{
            server_newer: server_last_update > client_last_update,
            time_diff: server_last_update - client_last_update
          }

          {:out_of_sync, diff}
      end
    rescue
      error ->
        {:error, "State comparison failed: #{inspect(error)}"}
    end
  end

  @doc """
  Handle client disconnection and cleanup.
  """
  @impl true
  def terminate(reason, socket) do
    Logger.debug("MapChannel: Client disconnected", reason: reason, topic: socket.topic)
    :ok
  end
end

defmodule CorroPortWeb.NavTabs do
  use Phoenix.Component
  use CorroPortWeb, :verified_routes
  import CorroPortWeb.CoreComponents

  @doc """
  Renders navigation tabs for the main application sections.

  ## Attributes
  - `active` - The currently active tab (:cluster, :messages, :node_info)
  """
  attr :active, :atom, required: true, values: [:cluster, :messages, :node_info]

  def nav_tabs(assigns) do
    ~H"""
    <div class="tabs tabs-boxed">
      <.link
        navigate={~p"/cluster"}
        class={["tab", if(@active == :cluster, do: "tab-active", else: "")]}
      >
        <.icon name="hero-server-stack" class="w-4 h-4 mr-2" />
        Cluster
      </.link>

      <.link
        navigate={~p"/messages"}
        class={["tab", if(@active == :messages, do: "tab-active", else: "")]}
      >
        <.icon name="hero-chat-bubble-left-right" class="w-4 h-4 mr-2" />
        Messages
      </.link>

      <.link
        navigate={~p"/node-info"}
        class={["tab", if(@active == :node_info, do: "tab-active", else: "")]}
      >
        <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-2" />
        Node Info
      </.link>
    </div>
    """
  end
end

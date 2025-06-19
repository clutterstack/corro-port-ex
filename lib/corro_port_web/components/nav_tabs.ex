defmodule CorroPortWeb.NavTabs do
  use Phoenix.Component
  use CorroPortWeb, :verified_routes
  import CorroPortWeb.CoreComponents

  @doc """
  Renders navigation tabs for the main application sections.

  ## Attributes
  - `active` - The currently active tab (:propagation, :cluster, :messages, :node)
  """
  attr :active, :atom, required: true, values: [:propagation, :cluster, :messages, :node]

  def nav_tabs(assigns) do
    ~H"""
    <div class="tabs tabs-boxed">
      <.link
        navigate={~p"/cluster"}
        class={["tab", if(@active == :cluster, do: "tab-active", else: "")]}
      >
        <.icon name="hero-server-stack" class="w-4 h-4 mr-2" /> Cluster
      </.link>

      <.link navigate={~p"/"} class={["tab", if(@active == :propagation, do: "tab-active", else: "")]}>
        <.icon name="hero-globe-alt" class="w-4 h-4 mr-2" /> Propagation
      </.link>

      <.link
        navigate={~p"/messages"}
        class={["tab", if(@active == :messages, do: "tab-active", else: "")]}
      >
        <.icon name="hero-chat-bubble-left-right" class="w-4 h-4 mr-2" /> Messages
      </.link>

      <.link navigate={~p"/node"} class={["tab", if(@active == :node, do: "tab-active", else: "")]}>
        <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-2" /> Node
      </.link>
    </div>
    """
  end
end

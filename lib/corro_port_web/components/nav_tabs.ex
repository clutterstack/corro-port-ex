defmodule CorroPortWeb.NavTabs do
  use Phoenix.Component
  use CorroPortWeb, :verified_routes
  import CorroPortWeb.CoreComponents

  @doc """
  Renders navigation tabs for the main application sections.

  ## Attributes
  - `active` - The currently active tab (:propagation, :cluster, :messages, :node, :analytics)
  """
  attr :active, :atom,
    required: true,
    values: [:propagation, :cluster, :messages, :node, :analytics, :query_console]

  def nav_tabs(assigns) do
    # Query console tab is always shown for now; apply auth/feature gating here when needed.
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

      <.link
        navigate={~p"/analytics"}
        class={["tab", if(@active == :analytics, do: "tab-active", else: "")]}
      >
        <.icon name="hero-chart-bar" class="w-4 h-4 mr-2" /> Analytics
      </.link>

      <.link
        navigate={~p"/query-console"}
        class={["tab", if(@active == :query_console, do: "tab-active", else: "")]}
      >
        <.icon name="hero-command-line" class="w-4 h-4 mr-2" /> Query Console
      </.link>
    </div>
    """
  end
end

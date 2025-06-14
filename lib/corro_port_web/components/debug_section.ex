defmodule CorroPortWeb.DebugSection do
  use Phoenix.Component

  def debug_section(assigns) do
    ~H"""
    <details :if={@cluster_info || @local_info} class="collapse collapse-arrow bg-base-200">
      <summary class="collapse-title text-sm font-medium">Raw API Response (Debug)</summary>
      <div class="collapse-content">
        <div :if={@cluster_info} class="mb-4">
          <h4 class="font-semibold mb-2">Cluster Info:</h4>
          <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@cluster_info, pretty: true) %></pre>
        </div>
        <div :if={@local_info} class="mb-4">
          <h4 class="font-semibold mb-2">Local Info:</h4>
          <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@local_info, pretty: true) %></pre>
        </div>
        <div :if={@node_messages != []} class="mb-4">
          <h4 class="font-semibold mb-2">Node Messages:</h4>
          <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@node_messages, pretty: true) %></pre>
        </div>
      </div>
    </details>
    """
  end
end

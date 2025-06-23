defmodule CorroPortWeb.MembersTable do
  use Phoenix.Component

  # TODO: Only include members that have been seen in the last @max_idle minutes
  # TODO: Exclude local node, since __corro_members always shows that as down
  #  (can we tell from corrosion which actor_id is currently the local node?)
  def cluster_members_table(assigns) do
    ~H"""
    <div class="card bg-base-100">
      <div class="card-body">
        <h3 class="card-title"><pre>__corro_members</pre> table entries</h3>

        <div :if={@cluster_info && Map.get(@cluster_info, :members, []) != []} class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Node ID</th>
                <th>Address</th>
                <th>State</th>
                <th>Incarnation</th>
                <th>Timestamp</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={member <- Map.get(@cluster_info || %{}, :members, [])}>
                <.cluster_member_row member={member} />
              </tr>
            </tbody>
          </table>
        </div>

        <.tracked_peers_section cluster_info={@cluster_info} />

        <div :if={
          Map.get(@cluster_info || %{}, :members, []) == [] &&
            Map.get(@cluster_info || %{}, :tracked_peers, []) == []
        }>
          <p class="text-base-content/70">
            No cluster members or peers found. This might be a single-node setup or the cluster is still forming.
          </p>
        </div>
      </div>
    </div>
    """
  end

  def cluster_member_row(assigns) do
    ~H"""
    <%= if Map.has_key?(@member, "parse_error") do %>
      <td colspan="5" class="text-error">
        Parse Error: {Map.get(@member, "parse_error")}
        <details class="mt-1">
          <summary class="text-xs cursor-pointer">Raw data</summary>
          <pre class="text-xs mt-1"><%= inspect(@member, pretty: true) %></pre>
        </details>
      </td>
    <% else %>
      <td class="font-mono text-xs">
        {case Map.get(@member, "member_id") do
          nil -> "Unknown"
          id -> String.slice(id, 0, 8) <> "..."
        end}
      </td>
      <td class="font-mono text-sm">
        {Map.get(@member, "member_addr", "Unknown")}
      </td>
      <td>
        <span class={member_state_badge_class(Map.get(@member, "member_state"))}>
          {Map.get(@member, "member_state", "Unknown")}
        </span>
      </td>
      <td>{Map.get(@member, "member_incarnation", "?")}</td>
      <td class="text-xs">
        {CorroPort.CorrosionParserAdapter.format_corrosion_timestamp(Map.get(@member, "member_ts"))}
      </td>
    <% end %>
    """
  end

  def tracked_peers_section(assigns) do
    ~H"""
    <div :if={@cluster_info && Map.get(@cluster_info, :tracked_peers, []) != []} class="mt-6">
      <h4 class="font-semibold mb-2">Tracked Peers</h4>
      <div class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Peer Info</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={peer <- Map.get(@cluster_info || %{}, :tracked_peers, [])}>
              <td class="font-mono text-sm">
                {inspect(peer) |> String.slice(0, 50)}...
              </td>
              <td>{inspect(peer)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def debug_section(assigns) do
    ~H"""
    <details class="collapse collapse-arrow bg-base-200">
      <summary class="collapse-title text-sm font-medium">Raw API Response (Debug)</summary>
      <div class="collapse-content">
        <div :if={@cluster_info} class="mb-4">
          <h4 class="font-semibold mb-2">Cluster Info:</h4>
          <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@cluster_info, pretty: true) %></pre>
        </div>
        <div :if={@node_messages != []} class="mb-4">
          <h4 class="font-semibold mb-2">Node Messages:</h4>
          <pre class="bg-base-300 p-4 rounded text-xs overflow-auto"><%= Jason.encode!(@node_messages, pretty: true) %></pre>
        </div>
      </div>
    </details>
    """
  end

  # Helper functions

  defp member_state_badge_class(state) do
    base_classes = "badge badge-sm"

    state_class =
      case state do
        "Alive" -> "badge-success"
        "Suspect" -> "badge-warning"
        "Down" -> "badge-error"
        _ -> "badge-neutral"
      end

    "#{base_classes} #{state_class}"
  end
end

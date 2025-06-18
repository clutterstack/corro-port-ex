defmodule CorroPortWeb.ClusterLive.DataFetcher do
  require Logger
  alias CorroPort.{ClusterAPI, DNSNodeDiscovery, ClusterMemberStore}

  def fetch_all_data() do
    # DNS-based expected nodes
    expected_nodes_result = DNSNodeDiscovery.get_expected_nodes()

    # Get CLI members from centralized store
    cli_member_data = ClusterMemberStore.get_members()

    # Basic cluster info (keep for debugging)
    cluster_result = ClusterAPI.get_cluster_info()

    # Extract active members and error from store
    active_members = cli_member_data.members
    cli_error = cli_member_data.last_error

    # Determine overall error state
    error = determine_overall_error(expected_nodes_result, cli_member_data, cluster_result)

    %{
      expected_nodes: case expected_nodes_result do
        {:ok, nodes} -> nodes
        {:error, _} -> []
      end,
      active_members: active_members,
      cli_error: cli_error,
      cluster_info: case cluster_result do
        {:ok, info} -> info
        {:error, _} -> nil
      end,
      error: error,
      last_updated: DateTime.utc_now()
    }
  end

  def fetch_all_data_with_messages() do
    # For ClusterLive - includes messages
    base_data = fetch_all_data()

    messages_result = CorroPort.MessagesAPI.get_latest_node_messages()

    node_messages = case messages_result do
      {:ok, messages} -> messages
      {:error, error} ->
        Logger.debug("Failed to fetch node messages (table might not exist yet): #{error}")
        []
    end

    Map.put(base_data, :node_messages, node_messages)
  end

  defp determine_overall_error(expected_nodes_result, cli_member_data, cluster_result) do
    cond do
      # Critical: Can't reach Corrosion API at all
      match?({:error, _}, cluster_result) ->
        "Failed to connect to Corrosion API"

      # Warning: DNS discovery failed
      match?({:error, _}, expected_nodes_result) ->
        "DNS node discovery failed - cluster expectations may be incomplete"

      # CLI service unavailable
      cli_member_data.status == :unavailable ->
        "CLI member service unavailable"

      # CLI failed but service is responding
      cli_member_data.last_error != nil ->
        case cli_member_data.last_error do
          {:cli_error, :timeout} ->
            "CLI cluster members query timed out - active member list may be stale"
          {:parse_error, _} ->
            "CLI command succeeded but output couldn't be parsed"
          {:cli_error, _reason} ->
            "CLI cluster members query failed - active member list may be stale"
          _ ->
            "CLI data issue - active member list may be unreliable"
        end

      # All good
      true ->
        nil
    end
  end
end

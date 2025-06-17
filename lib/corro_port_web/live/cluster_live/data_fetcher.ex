defmodule CorroPortWeb.ClusterLive.DataFetcher do
  require Logger
  alias CorroPort.{ClusterAPI, DNSNodeDiscovery, CorrosionCLI}

  def fetch_all_data() do
    # DNS-based expected nodes
    expected_nodes_result = DNSNodeDiscovery.get_expected_nodes()

    # CLI-based active members (async with 10s timeout)
    cli_members_task = CorrosionCLI.cluster_members_async()

    # Basic cluster info (keep for debugging)
    cluster_result = ClusterAPI.get_cluster_info()
    # This always succeeds
    {:ok, local_info} = ClusterAPI.get_info()

    # Wait for CLI with 10s timeout
    cli_members_result =
      try do
        Task.await(cli_members_task, 10_000)
      catch
        :exit, _ -> {:error, :timeout}
      end

    # Parse CLI members if successful
    {active_members, cli_error} = case cli_members_result do
      {:ok, raw_output} ->
        case CorroPort.CorrosionParser.parse_cluster_members(raw_output) do
          {:ok, members} -> {members, nil}
          {:error, reason} -> {[], {:parse_error, reason}}
        end
      {:error, reason} -> {[], {:cli_error, reason}}
    end

    # Determine overall error state
    error = determine_overall_error(expected_nodes_result, cli_members_result, cluster_result)

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
      local_info: local_info,
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

  defp determine_overall_error(expected_nodes_result, cli_members_result, cluster_result) do
    cond do
      # Critical: Can't reach Corrosion API at all
      match?({:error, _}, cluster_result) ->
        "Failed to connect to Corrosion API"

      # Warning: DNS discovery failed
      match?({:error, _}, expected_nodes_result) ->
        "DNS node discovery failed - cluster expectations may be incomplete"

      # CLI failed but other things work
      match?({:error, _}, cli_members_result) ->
        "CLI cluster members query failed - active member list may be stale"

      # All good
      true ->
        nil
    end
  end
end

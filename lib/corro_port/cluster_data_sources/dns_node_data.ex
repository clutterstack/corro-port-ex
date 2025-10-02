defmodule CorroPort.DNSNodeData do
  @moduledoc """
  Discovers expected cluster nodes via DNS and computes their regions.

  This module manages the authoritative list of nodes that should exist
  in the cluster, typically from Fly.io DNS TXT records.
  """

  use GenServer
  require Logger

  @cache_duration 60_000  # 1 minute cache
  @dns_timeout 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get expected nodes data with computed regions.

  Returns:
  %{
    nodes: {:ok, ["ams-machine1", ...]} | {:error, :dns_failed},
    regions: ["ams", "fra", "iad"],  # Always a list, empty on error
    cache_status: %{last_updated: dt, error: nil | reason}
  }
  """
  def get_expected_data do
    GenServer.call(__MODULE__, :get_expected_data)
  end

  @doc """
  Force refresh of the DNS cache.
  """
  def refresh_cache do
    GenServer.cast(__MODULE__, :refresh_cache)
  end

  @doc """
  Subscribe to expected nodes updates.
  Receives: {:expected_nodes_updated, expected_data}
  """
  def subscribe do
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "dns_node_data")
  end

  @doc """
  Get cache status for debugging.
  """
  def get_cache_status do
    GenServer.call(__MODULE__, :get_cache_status)
  end

  # GenServer Implementation

  def init(_opts) do
    Logger.info("DNSNodeData starting...")

    state = %{
      nodes_result: nil,
      regions: [],
      cache_timestamp: nil,
      last_error: nil
    }

    # Start initial fetch after a brief delay
    Process.send_after(self(), :initial_fetch, 1000)

    {:ok, state}
  end

  def handle_call(:get_expected_data, _from, state) do
    data = build_expected_data(state)
    {:reply, data, state}
  end

  def handle_call(:get_cache_status, _from, state) do
    status = %{
      last_updated: state.cache_timestamp,
      cache_age_ms: cache_age_ms(state.cache_timestamp),
      is_cache_fresh: is_cache_fresh?(state.cache_timestamp),
      error: state.last_error
    }

    {:reply, status, state}
  end

  def handle_cast(:refresh_cache, state) do
    Logger.info("DNSNodeData: Manual cache refresh requested")
    new_state = perform_fetch(state)
    {:noreply, new_state}
  end

  def handle_info(:initial_fetch, state) do
    Logger.info("DNSNodeData: Performing initial DNS fetch")
    new_state = perform_fetch(state)
    {:noreply, new_state}
  end

  # Private Functions

  defp perform_fetch(state) do
    case fetch_nodes_from_dns() do
      {:ok, nodes} ->
        regions = CorroPort.RegionExtractor.extract_from_nodes({:ok, nodes})
        local_node_id = CorroPort.LocalNode.get_node_id()

        # Exclude local node from expected nodes
        filtered_nodes = Enum.reject(nodes, &(&1 == local_node_id))

        new_state = %{
          state |
          nodes_result: {:ok, filtered_nodes},
          regions: regions,
          cache_timestamp: DateTime.utc_now(),
          last_error: nil
        }

        Logger.info("DNSNodeData: Successfully fetched #{length(filtered_nodes)} expected nodes")
        broadcast_update(new_state)
        new_state

      {:error, reason} ->
        Logger.warning("DNSNodeData: DNS fetch failed: #{inspect(reason)}")

        new_state = %{
          state |
          nodes_result: {:error, reason},
          regions: [],  # Empty regions on error
          cache_timestamp: DateTime.utc_now(),
          last_error: reason
        }

        broadcast_update(new_state)
        new_state
    end
  end

  defp fetch_nodes_from_dns do
    case get_fly_app_name() do
      nil ->
        Logger.debug("DNSNodeData: Not in Fly.io environment, using development fallback")
        get_development_fallback()

      app_name ->
        dns_name = "vms.#{app_name}.internal"
        Logger.debug("DNSNodeData: Querying DNS TXT record: #{dns_name}")

        case query_dns_txt(dns_name) do
          {:ok, txt_records} ->
            parse_txt_records(txt_records)

          {:error, reason} ->
            Logger.warning("DNSNodeData: DNS query failed for #{dns_name}: #{inspect(reason)}")
            {:error, {:dns_query_failed, reason}}
        end
    end
  end

  defp get_fly_app_name do
    System.get_env("FLY_APP_NAME") ||
      Application.get_env(:corro_port, :dns_cluster_query) ||
      get_in(Application.get_env(:corro_port, :node_config), [:fly_app_name])
  end

  defp query_dns_txt(dns_name) do
    try do
      dns_charlist = String.to_charlist(dns_name)

      case :inet_res.lookup(dns_charlist, :in, :txt, timeout: @dns_timeout) do
        [] ->
          {:error, :no_txt_records}

        txt_records when is_list(txt_records) ->
          string_records =
            Enum.map(txt_records, fn record ->
              record |> List.flatten() |> List.to_string()
            end)

          {:ok, string_records}

        error ->
          {:error, {:inet_res_error, error}}
      end
    rescue
      e ->
        {:error, {:exception, e}}
    end
  end

  defp parse_txt_records(txt_records) when is_list(txt_records) do
    try do
      all_nodes =
        txt_records
        |> Enum.flat_map(&parse_single_txt_record/1)
        |> Enum.uniq()
        |> Enum.sort()

      Logger.info("DNSNodeData: Parsed #{length(all_nodes)} nodes from DNS")
      {:ok, all_nodes}
    rescue
      e ->
        Logger.warning("DNSNodeData: Error parsing TXT records: #{inspect(e)}")
        {:error, {:parse_error, e}}
    end
  end

  defp parse_single_txt_record(txt_record) when is_binary(txt_record) do
    # Parse format: "machine_id region,machine_id region,..."
    txt_record
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_machine_region_pair/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_machine_region_pair(pair_string) when is_binary(pair_string) do
    case String.split(pair_string, " ", trim: true) do
      [machine_id, region] when byte_size(machine_id) > 0 and byte_size(region) > 0 ->
        "#{region}-#{machine_id}"

      _ ->
        Logger.warning("DNSNodeData: Invalid machine/region pair: #{inspect(pair_string)}")
        nil
    end
  end

  defp get_development_fallback do
    Logger.debug("DNSNodeData: Using development fallback")

    _local_node_id = CorroPort.LocalNode.get_node_id()
    all_dev_nodes = ["dev-node1", "dev-node2", "dev-node3"]

    {:ok, all_dev_nodes}
  end

  defp build_expected_data(state) do
    %{
      nodes: state.nodes_result || {:error, :not_loaded},
      regions: state.regions,
      cache_status: %{
        last_updated: state.cache_timestamp,
        error: state.last_error
      }
    }
  end

  defp broadcast_update(state) do
    expected_data = build_expected_data(state)
    Phoenix.PubSub.broadcast(CorroPort.PubSub, "dns_node_data", {:expected_nodes_updated, expected_data})
  end

  defp is_cache_fresh?(nil), do: false
  defp is_cache_fresh?(timestamp) do
    DateTime.diff(DateTime.utc_now(), timestamp, :millisecond) < @cache_duration
  end

  defp cache_age_ms(nil), do: nil
  defp cache_age_ms(timestamp) do
    DateTime.diff(DateTime.utc_now(), timestamp, :millisecond)
  end
end

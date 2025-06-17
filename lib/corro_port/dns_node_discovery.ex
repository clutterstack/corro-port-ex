defmodule CorroPort.DNSNodeDiscovery do
  @moduledoc """
  Discovers cluster nodes via DNS TXT records from Fly.io.

  Queries the DNS TXT record at "vms.${FLY_APP_NAME}.internal" to get
  an authoritative list of machines in the cluster.

  TXT record format: "machine_id region,machine_id region,..."
  Example: "1857961b2d73e8 yul,185e276f707e78 syd,6830d10c463198 ewr"
  """

  require Logger
  use GenServer

  # 1 minute cache
  @cache_duration 60_000
  # 5 second DNS timeout
  @dns_timeout 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the list of expected node IDs from DNS, excluding the local node.

  Returns cached result if available and fresh, otherwise queries DNS.

  ## Returns
  - `{:ok, [node_id]}` - List of node IDs in "region-machine_id" format
  - `{:error, reason}` - DNS query failed
  """
  def get_expected_nodes do
    case GenServer.call(__MODULE__, :get_expected_nodes, @dns_timeout + 1000) do
      {:ok, nodes} ->
        {:ok, nodes}

      {:error, reason} ->
        Logger.warning("DNSNodeDiscovery: Failed to get expected nodes: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("DNSNodeDiscovery: Exception getting expected nodes: #{inspect(e)}")
      {:error, {:exception, e}}
  end

  @doc """
  Forces a refresh of the DNS cache.
  """
  def refresh_cache do
    GenServer.cast(__MODULE__, :refresh_cache)
  end

  @doc """
  Gets the current cache status for debugging.
  """
  def get_cache_status do
    GenServer.call(__MODULE__, :get_cache_status)
  end

  # GenServer Implementation

  def init(_opts) do
    Logger.info("DNSNodeDiscovery starting...")

    state = %{
      cached_nodes: nil,
      cache_timestamp: nil,
      last_query_result: nil
    }

    {:ok, state}
  end

  def handle_call(:get_expected_nodes, _from, state) do
    case get_cached_or_fetch_nodes(state) do
      {:ok, nodes, new_state} ->
        {:reply, {:ok, nodes}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:get_cache_status, _from, state) do
    status = %{
      cached_nodes: state.cached_nodes,
      cache_timestamp: state.cache_timestamp,
      cache_age_ms: cache_age_ms(state.cache_timestamp),
      is_cache_fresh: is_cache_fresh?(state.cache_timestamp),
      last_query_result: state.last_query_result
    }

    {:reply, status, state}
  end

  def handle_cast(:refresh_cache, state) do
    Logger.info("DNSNodeDiscovery: Manual cache refresh requested")

    case fetch_nodes_from_dns() do
      {:ok, nodes} ->
        new_state = %{
          state
          | cached_nodes: nodes,
            cache_timestamp: System.monotonic_time(:millisecond),
            last_query_result: {:ok, length(nodes)}
        }

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("DNSNodeDiscovery: Cache refresh failed: #{inspect(reason)}")
        new_state = %{state | last_query_result: {:error, reason}}
        {:noreply, new_state}
    end
  end

  # Private Functions

  defp get_cached_or_fetch_nodes(state) do
    if is_cache_fresh?(state.cache_timestamp) do
      Logger.debug(
        "DNSNodeDiscovery: Using cached nodes (#{length(state.cached_nodes || [])} nodes)"
      )

      {:ok, state.cached_nodes || [], state}
    else
      Logger.debug("DNSNodeDiscovery: Cache expired or empty, fetching from DNS")

      case fetch_nodes_from_dns() do
        {:ok, nodes} ->
          new_state = %{
            state
            | cached_nodes: nodes,
              cache_timestamp: System.monotonic_time(:millisecond),
              last_query_result: {:ok, length(nodes)}
          }

          {:ok, nodes, new_state}

        {:error, reason} ->
          Logger.warning("DNSNodeDiscovery: DNS fetch failed: #{inspect(reason)}")
          new_state = %{state | last_query_result: {:error, reason}}

          # Return cached data if available, even if stale
          if state.cached_nodes do
            Logger.info("DNSNodeDiscovery: Using stale cache due to DNS failure")
            {:ok, state.cached_nodes, new_state}
          else
            {:error, reason, new_state}
          end
      end
    end
  end

  defp fetch_nodes_from_dns do
    # Check if we're in production with Fly.io environment
    case get_fly_app_name() do
      nil ->
        Logger.debug("DNSNodeDiscovery: Not in Fly.io environment, using development fallback")
        get_development_fallback()

      app_name ->
        dns_name = "vms.#{app_name}.internal"
        Logger.debug("DNSNodeDiscovery: Querying DNS TXT record: #{dns_name}")

        case query_dns_txt(dns_name) do
          {:ok, txt_records} ->
            parse_txt_records(txt_records)

          {:error, reason} ->
            Logger.warning(
              "DNSNodeDiscovery: DNS query failed for #{dns_name}: #{inspect(reason)}"
            )

            {:error, {:dns_query_failed, reason}}
        end
    end
  end

  defp get_fly_app_name do
    # Try multiple sources for the app name
    System.get_env("FLY_APP_NAME") ||
      Application.get_env(:corro_port, :dns_cluster_query) ||
      get_in(Application.get_env(:corro_port, :node_config), [:fly_app_name])
  end

  defp query_dns_txt(dns_name) do
    try do
      # Convert string to charlist for :inet_res
      dns_charlist = String.to_charlist(dns_name)

      case :inet_res.lookup(dns_charlist, :in, :txt, timeout: @dns_timeout) do
        [] ->
          {:error, :no_txt_records}

        txt_records when is_list(txt_records) ->
          # Convert charlists back to strings
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
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    try do
      # Parse all TXT records and combine results
      all_nodes =
        txt_records
        |> Enum.flat_map(&parse_single_txt_record/1)
        |> Enum.uniq()
        |> Enum.reject(fn node_id -> node_id == local_node_id end)
        |> Enum.sort()

      Logger.info(
        "DNSNodeDiscovery: Parsed #{length(all_nodes)} expected nodes (excluding local): #{inspect(all_nodes)}"
      )

      {:ok, all_nodes}
    rescue
      e ->
        Logger.warning("DNSNodeDiscovery: Error parsing TXT records: #{inspect(e)}")
        {:error, {:parse_error, e}}
    end
  end

  defp parse_single_txt_record(txt_record) when is_binary(txt_record) do
    # Parse format: "machine_id region,machine_id region,..."
    # Example: "1857961b2d73e8 yul,185e276f707e78 syd,6830d10c463198 ewr"

    txt_record
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_machine_region_pair/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_machine_region_pair(pair_string) when is_binary(pair_string) do
    case String.split(pair_string, " ", trim: true) do
      [machine_id, region] when byte_size(machine_id) > 0 and byte_size(region) > 0 ->
        # Create node ID in our standard format: "region-machine_id"
        "#{region}-#{machine_id}"

      _ ->
        Logger.warning("DNSNodeDiscovery: Invalid machine/region pair: #{inspect(pair_string)}")
        nil
    end
  end

  defp get_development_fallback do
    # In development, try to use the existing bootstrap-based discovery
    # but keep it simple - just return the basic node list
    Logger.debug("DNSNodeDiscovery: Using development fallback")

    local_node_config = Application.get_env(:corro_port, :node_config, %{})
    local_node_id = local_node_config[:node_id] || "dev-node1"

    # Generate a simple 3-node cluster for development
    all_dev_nodes = ["dev-node1", "dev-node2", "dev-node3"]
    expected_nodes = Enum.reject(all_dev_nodes, fn id -> id == local_node_id end)

    Logger.debug("DNSNodeDiscovery: Development fallback nodes: #{inspect(expected_nodes)}")
    {:ok, expected_nodes}
  end

  defp is_cache_fresh?(nil), do: false

  defp is_cache_fresh?(timestamp) do
    age_ms = System.monotonic_time(:millisecond) - timestamp
    age_ms < @cache_duration
  end

  defp cache_age_ms(nil), do: nil

  defp cache_age_ms(timestamp) do
    System.monotonic_time(:millisecond) - timestamp
  end
end

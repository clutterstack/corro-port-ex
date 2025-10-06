defmodule CorroPort.DNSLookup do
  @moduledoc """
  Simple DNS lookup for expected cluster nodes.

  Performs direct DNS queries without caching - OS DNS caching is sufficient.
  """

  require Logger

  @dns_timeout 5_000

  @doc """
  Get DNS-discovered nodes data with computed regions.

  Returns:
  %{
    nodes: {:ok, ["ams-machine1", ...]} | {:error, :dns_failed},
    regions: ["ams", "fra", "iad"],  # Always a list, empty on error
    cache_status: %{last_updated: dt, error: nil | reason}
  }
  """
  def get_dns_data do
    timestamp = DateTime.utc_now()

    case fetch_nodes_from_dns() do
      {:ok, nodes} ->
        regions = CorroPort.RegionExtractor.extract_from_nodes({:ok, nodes})
        local_node_id = CorroPort.LocalNode.get_node_id()

        # Exclude local node from expected nodes
        filtered_nodes = Enum.reject(nodes, &(&1 == local_node_id))

        %{
          nodes: {:ok, filtered_nodes},
          regions: regions,
          cache_status: %{
            last_updated: timestamp,
            error: nil
          }
        }

      {:error, reason} ->
        Logger.warning("DNSLookup: DNS fetch failed: #{inspect(reason)}")

        %{
          nodes: {:error, reason},
          regions: [],
          cache_status: %{
            last_updated: timestamp,
            error: reason
          }
        }
    end
  end

  # Private Functions

  defp fetch_nodes_from_dns do
    case get_fly_app_name() do
      nil ->
        Logger.debug("DNSLookup: Not in Fly.io environment, using development fallback")
        get_development_fallback()

      app_name ->
        dns_name = "vms.#{app_name}.internal"
        Logger.debug("DNSLookup: Querying DNS TXT record: #{dns_name}")

        case query_dns_txt(dns_name) do
          {:ok, txt_records} ->
            parse_txt_records(txt_records)

          {:error, reason} ->
            Logger.warning("DNSLookup: DNS query failed for #{dns_name}: #{inspect(reason)}")
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

      Logger.info("DNSLookup: Parsed #{length(all_nodes)} nodes from DNS")
      {:ok, all_nodes}
    rescue
      e ->
        Logger.warning("DNSLookup: Error parsing TXT records: #{inspect(e)}")
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
        Logger.warning("DNSLookup: Invalid machine/region pair: #{inspect(pair_string)}")
        nil
    end
  end

  @doc """
  Returns the development fallback node list for local cluster testing.

  Returns `{:ok, ["dev-node1", "dev-node2", "dev-node3"]}`
  """
  def get_development_fallback do
    Logger.debug("DNSLookup: Using development fallback")
    all_dev_nodes = ["dev-node1", "dev-node2", "dev-node3"]
    {:ok, all_dev_nodes}
  end
end

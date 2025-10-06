# Helper functions to extract display logic from ClusterLive template

defmodule CorroPortWeb.DisplayHelpers do
  @moduledoc """
  Helper functions for ClusterLive to determine display content and styling.
  Moves conditional logic out of the template for better maintainability.
  """

  @doc """
  Determines the CSS classes for refresh buttons based on data state.
  """
  def refresh_button_class(data, base_class \\ "btn btn-xs") do
    if has_error?(data) do
      "#{base_class} btn-error"
    else
      "#{base_class} btn-outline"
    end
  end

  @doc """
  Builds refresh button configuration for action buttons.
  """
  def refresh_button_config(data, action, label, icon) do
    %{
      action: action,
      label: label,
      icon: icon,
      class: refresh_button_class(data, "btn btn-xs"),
      show_warning: has_error?(data)
    }
  end

  @doc """
  Builds system button configuration (different error checking).
  """
  def system_button_config(data, action, label, icon) do
    %{
      action: action,
      label: label,
      icon: icon,
      class: system_refresh_button_class(data),
      show_warning: !is_nil(data.cache_status.error)
    }
  end

  @doc """
  Builds all alert configurations for display.
  """
  def build_all_alerts(dns_data, cli_data, api_data) do
    [
      dns_alert_config(dns_data),
      cli_alert_config(cli_data),
      api_alert_config(api_data)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Checks if data has an error state.
  """
  def has_error?(data) do
    case get_data_result(data) do
      {:error, _} -> true
      _ -> false
    end
  end

  @doc """
  Gets the error reason from data, returns nil if no error.
  """
  def get_error_reason(data) do
    case get_data_result(data) do
      {:error, reason} -> reason
      _ -> nil
    end
  end

  @doc """
  Determines if a warning indicator should be shown for data.
  """
  def show_warning?(data) do
    has_error?(data)
  end

  @doc """
  Gets the count from data result, handling error states.
  """
  def get_count(data, key) do
    case Map.get(data, key) do
      {:ok, list} when is_list(list) -> length(list)
      {:error, _} -> nil
      _ -> 0
    end
  end

  @doc """
  Formats a count for display, showing "?" for error states.
  """
  def format_count(data, key) do
    case get_count(data, key) do
      nil -> "?"
      count -> to_string(count)
    end
  end

  @doc """
  Gets display content for count with error styling.
  Returns a map with content and CSS class.
  """
  def count_display(data, key) do
    case get_count(data, key) do
      nil -> %{content: "?", class: "text-error"}
      count -> %{content: to_string(count), class: ""}
    end
  end

  @doc """
  Formats cache status for display.
  """
  def cache_status_display(cache_status) do
    case cache_status do
      %{last_updated: nil} ->
        "Never loaded"

      %{last_updated: updated, error: nil} ->
        "Updated #{Calendar.strftime(updated, "%H:%M:%S")}"

      %{last_updated: updated, error: error} ->
        "Failed at #{Calendar.strftime(updated, "%H:%M:%S")} (#{format_error_reason(error)})"

      _ ->
        "Unknown status"
    end
  end

  @doc """
  Determines if an alert should be shown for data.
  """
  def show_alert?(data) do
    has_error?(data)
  end

  @doc """
  Gets alert configuration for DNS data.
  """
  def dns_alert_config(dns_data) do
    case get_error_reason(dns_data) do
      nil ->
        nil

      reason ->
        %{
          class: "alert alert-warning",
          icon: "hero-exclamation-triangle",
          title: "DNS Discovery Failed",
          message: "Error: #{format_error_reason(reason)} - Expected regions may be incomplete"
        }
    end
  end

  @doc """
  Gets alert configuration for CLI data.
  """
  def cli_alert_config(cli_data) do
    case get_error_reason(cli_data) do
      nil ->
        nil

      reason ->
        %{
          class: "alert alert-error",
          icon: "hero-exclamation-triangle",
          title: "CLI Data Failed",
          message: "Error: #{format_error_reason(reason)} - Active member list may be stale"
        }
    end
  end

  @doc """
  Gets alert configuration for API data.
  """
  def api_alert_config(api_data) do
    case api_data.cache_status.error do
      nil ->
        nil

      error ->
        %{
          class: "alert alert-warning",
          icon: "hero-exclamation-triangle",
          title: "API Data Issue",
          message: "Error: #{format_error_reason(error)} - Cluster info may be incomplete"
        }
    end
  end

  @doc """
  Returns tooltip/help text for data sources.
  """
  def data_source_tooltip(source) do
    case source do
      :dns ->
        "Discovered via DNS TXT record query. Shows nodes that should exist based on infrastructure config."

      :cli ->
        "Fetched via 'corro cluster members' CLI command. Shows Corrosion nodes actively participating in gossip protocol."

      :api ->
        "Queried from Corrosion API (__corro_members table). Database-level cluster state from the agent."

      _ ->
        ""
    end
  end

  @doc """
  Returns source label for display.
  """
  def data_source_label(source) do
    case source do
      :dns -> "DNS Query"
      :cli -> "CLI Command"
      :api -> "Corrosion API"
      _ -> "Unknown"
    end
  end

  @doc """
  Builds display configuration for cluster summary stats.
  """
  def cluster_summary_stats(dns_data, cli_data, api_data, dns_regions, cli_regions) do
    dns_display = count_display(dns_data, :nodes)
    cli_display = count_display(cli_data, :members)

    %{
      dns: %{
        display: dns_display,
        regions_count: length(dns_regions),
        source_label: data_source_label(:dns),
        tooltip: data_source_tooltip(:dns),
        last_updated: dns_data.cache_status.last_updated
      },
      cli: %{
        display: cli_display,
        regions_count: length(cli_regions),
        source_label: data_source_label(:cli),
        tooltip: data_source_tooltip(:cli),
        last_updated: cli_data.cache_status.last_updated
      }
    }
  end

  @doc """
  Builds CLI member data for the CLIMembersTable component.
  """
  def build_cli_member_data(cli_data) do
    case cli_data.members do
      {:ok, members} ->
        %{
          members: members,
          member_count: length(members),
          status: :ok,
          last_updated: cli_data.cache_status.last_updated,
          last_error: nil
        }

      {:error, reason} ->
        %{
          members: [],
          member_count: 0,
          status: :error,
          last_updated: cli_data.cache_status.last_updated,
          last_error: reason
        }
    end
  end

  @doc """
  Extracts CLI error from CLI data for the CLIMembersTable component.
  """
  def extract_cli_error(cli_data) do
    case cli_data.members do
      {:ok, _} -> nil
      {:error, reason} -> reason
    end
  end

  @doc """
  Builds cache status display data for all data sources.
  """
  def all_cache_status(dns_data, cli_data, api_data) do
    %{
      dns: cache_status_display(dns_data.cache_status),
      cli: cache_status_display(cli_data.cache_status),
      api: cache_status_display(api_data.cache_status)
    }
  end

  @doc """
  Formats a timestamp for consistent display across the app.
  """
  def format_timestamp(nil), do: "Unknown"

  def format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> timestamp
    end
  end

  def format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  def format_timestamp(_), do: "Unknown"

  # Private helper functions

  defp get_data_result(data) do
    # Try different keys that might contain the result
    Map.get(data, :nodes) || Map.get(data, :members) || {:ok, []}
  end

  # Private helper for system button class
  defp system_refresh_button_class(data) do
    base_class = "btn btn-xs"

    if data.cache_status.error do
      "#{base_class} btn-error"
    else
      "#{base_class} btn-outline"
    end
  end

  @doc """
  Builds CLI status information for display.
  """
  def build_cli_status_info(cli_member_data) do
    %{
      status_badge_class: cli_status_badge_class(cli_member_data.status),
      status_text: format_cli_status(cli_member_data.status),
      last_updated_text: format_cli_last_updated(cli_member_data.last_updated),
      member_count: cli_member_data.member_count
    }
  end

  @doc """
  Determines CLI status badge CSS classes.
  """
  def cli_status_badge_class(status) do
    base = "badge badge-sm"

    case status do
      :ok -> "#{base} badge-success"
      :fetching -> "#{base} badge-info"
      :error -> "#{base} badge-error"
      :unavailable -> "#{base} badge-warning"
      :initializing -> "#{base} badge-neutral"
      _ -> "#{base} badge-neutral"
    end
  end

  @doc """
  Formats CLI status for display.
  """
  def format_cli_status(status) do
    case status do
      :ok -> "Active"
      :fetching -> "Fetching"
      :error -> "Error"
      :unavailable -> "Unavailable"
      :initializing -> "Starting"
      _ -> "Unknown"
    end
  end

  @doc """
  Determines if CLI fetching spinner should be shown.
  """
  def show_fetching_spinner?(cli_member_data) do
    cli_member_data && cli_member_data.status == :fetching
  end

  @doc """
  Determines if CLI error should be displayed.
  """
  def should_show_cli_error?(cli_error) do
    !is_nil(cli_error)
  end

  @doc """
  Determines if CLI has successful members to display.
  """
  def has_successful_cli_members?(cli_member_data) do
    cli_member_data && cli_member_data.members != []
  end

  @doc """
  Determines if CLI empty state should be shown.
  """
  def show_cli_empty_state?(cli_member_data, cli_error) do
    cli_member_data && cli_member_data.members == [] && is_nil(cli_error)
  end

  @doc """
  Determines if CLI loading state should be shown.
  """
  def show_cli_loading_state?(cli_member_data) do
    is_nil(cli_member_data) || cli_member_data.status == :initializing
  end

  @doc """
  Builds CLI error configuration for display.
  """
  def build_cli_error_config(cli_error) do
    {title, message} =
      case cli_error do
        {:cli_error, :timeout} ->
          {"CLI Data Issue", "CLI command timed out after 15 seconds"}

        {:cli_error, reason} ->
          {"CLI Data Issue", "CLI command failed: #{inspect(reason)}"}

        {:parse_error, _reason} ->
          {"CLI Data Issue", "CLI command succeeded but output couldn't be parsed"}

        {:service_unavailable, msg} ->
          {"CLI Data Issue", msg}

        _ ->
          {"CLI Data Issue", "Unknown CLI error: #{inspect(cli_error)}"}
      end

    %{title: title, message: message}
  end

  @doc """
  Formats error reasons consistently across the application.
  """
  def format_error_reason(reason) do
    case reason do
      :dns_failed -> "DNS lookup failed"
      :cli_timeout -> "CLI command timed out"
      {:cli_failed, _} -> "CLI command failed"
      {:parse_failed, _} -> "Failed to parse CLI output"
      :service_unavailable -> "Service unavailable"
      {:tracking_failed, _} -> "Failed to start tracking"
      {:cluster_api_failed, _} -> "Cluster API connection failed"
      {:fetch_exception, _} -> "System data fetch failed"
      _ -> "#{inspect(reason)}"
    end
  end

  @doc """
  Formats CLI last updated timestamp for display.
  """
  def format_cli_last_updated(nil), do: nil

  def format_cli_last_updated(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> timestamp
    end
  end

  def format_cli_last_updated(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  def format_cli_last_updated(_), do: nil

  # DNS Node Data Helpers

  @doc """
  Builds DNS node data for the DNSNodesTable component.
  """
  def build_dns_node_data(dns_data) do
    case dns_data.nodes do
      {:ok, nodes} ->
        parsed_nodes = Enum.map(nodes, &parse_dns_node_id/1)
        status = if dns_data.cache_status.error, do: :error, else: :ok

        %{
          nodes: parsed_nodes,
          node_count: length(parsed_nodes),
          status: status,
          last_updated: dns_data.cache_status.last_updated,
          last_error: dns_data.cache_status.error
        }

      {:error, reason} ->
        %{
          nodes: [],
          node_count: 0,
          status: :error,
          last_updated: dns_data.cache_status.last_updated,
          last_error: reason
        }
    end
  end

  @doc """
  Parses a DNS node ID into region and machine ID components.
  Expected format: "region-machineid" (e.g., "ams-machine1")
  """
  def parse_dns_node_id(node_id) when is_binary(node_id) do
    case String.split(node_id, "-", parts: 2) do
      [region, machine_id] ->
        %{
          "region" => region,
          "machine_id" => machine_id,
          "full_id" => node_id
        }

      [single_part] ->
        # Handle case where there's no dash
        %{
          "region" => "unknown",
          "machine_id" => single_part,
          "full_id" => node_id
        }
    end
  end

  def parse_dns_node_id(_),
    do: %{"region" => "unknown", "machine_id" => "unknown", "full_id" => "unknown"}

  @doc """
  Builds DNS status information for display.
  """
  def build_dns_status_info(dns_node_data) do
    %{
      status_badge_class: dns_status_badge_class(dns_node_data.status),
      status_text: format_dns_status(dns_node_data.status),
      last_updated_text: format_dns_last_updated(dns_node_data.last_updated),
      node_count: dns_node_data.node_count
    }
  end

  @doc """
  Determines DNS status badge CSS classes.
  """
  def dns_status_badge_class(status) do
    base = "badge badge-sm"

    case status do
      :ok -> "#{base} badge-success"
      :fetching -> "#{base} badge-info"
      :error -> "#{base} badge-error"
      :unavailable -> "#{base} badge-warning"
      :initializing -> "#{base} badge-neutral"
      _ -> "#{base} badge-neutral"
    end
  end

  @doc """
  Formats DNS status for display.
  """
  def format_dns_status(status) do
    case status do
      :ok -> "Active"
      :fetching -> "Fetching"
      :error -> "Error"
      :unavailable -> "Unavailable"
      :initializing -> "Starting"
      _ -> "Unknown"
    end
  end

  @doc """
  Formats DNS last updated timestamp for display.
  """
  def format_dns_last_updated(nil), do: nil

  def format_dns_last_updated(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> timestamp
    end
  end

  def format_dns_last_updated(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  def format_dns_last_updated(_), do: nil

  @doc """
  Extracts DNS error from DNS data for the DNSNodesTable component.
  """
  def extract_dns_error(dns_data) do
    case dns_data.nodes do
      {:ok, _} -> nil
      {:error, reason} -> reason
    end
  end

  @doc """
  Determines if DNS error should be displayed.
  """
  def should_show_dns_error?(dns_error) do
    !is_nil(dns_error)
  end

  @doc """
  Determines if DNS has successful nodes to display.
  """
  def has_successful_dns_nodes?(dns_node_data) do
    dns_node_data && dns_node_data.nodes != []
  end

  @doc """
  Determines if DNS empty state should be shown.
  """
  def show_dns_empty_state?(dns_node_data, dns_error) do
    dns_node_data && dns_node_data.nodes == [] && is_nil(dns_error)
  end

  @doc """
  Determines if DNS loading state should be shown.
  """
  def show_dns_loading_state?(dns_node_data) do
    is_nil(dns_node_data) || dns_node_data.status == :initializing
  end

  @doc """
  Builds DNS error configuration for display.
  """
  def build_dns_error_config(dns_error) do
    {title, message} =
      case dns_error do
        {:dns_query_failed, :no_txt_records} ->
          {"DNS Data Issue", "No DNS TXT records found for cluster discovery"}

        {:dns_query_failed, reason} ->
          {"DNS Data Issue", "DNS query failed: #{inspect(reason)}"}

        {:parse_error, _reason} ->
          {"DNS Data Issue", "DNS query succeeded but output couldn't be parsed"}

        _ ->
          {"DNS Data Issue", "Unknown DNS error: #{inspect(dns_error)}"}
      end

    %{title: title, message: message}
  end
end

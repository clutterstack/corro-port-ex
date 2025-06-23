defmodule CorroPort.CorrosionParserAdapter do
  @moduledoc """
  Adapter module that wraps the new CorroCLI.Parser library to maintain compatibility
  with CorroPort's existing CorrosionParser interface.

  This adapter provides the same interface as the original CorroPort.CorrosionParser module
  while delegating to the new CorroCLI.Parser library.
  """

  require Logger

  @doc """
  Parses cluster members concatenated JSON output into a structured format.
  
  Delegates to CorroCLI.Parser.parse_cluster_members/1.
  """
  def parse_cluster_members(cli_output) do
    CorroCLI.Parser.parse_cluster_members(cli_output)
  end

  @doc """
  Parses cluster info concatenated JSON output.
  
  Delegates to CorroCLI.Parser.parse_cluster_info/1.
  """
  def parse_cluster_info(cli_output) do
    CorroCLI.Parser.parse_cluster_info(cli_output)
  end

  @doc """
  Parses cluster status concatenated JSON output.
  
  Delegates to CorroCLI.Parser.parse_cluster_status/1.
  """
  def parse_cluster_status(cli_output) do
    CorroCLI.Parser.parse_cluster_status(cli_output)
  end

  @doc """
  Parses concatenated JSON objects from corrosion command output.
  
  Delegates to CorroCLI.Parser.parse_json_output/2.
  """
  def parse_cli_output(output, enhancer_fun \\ &Function.identity/1) do
    CorroCLI.Parser.parse_json_output(output, enhancer_fun)
  end

  @doc """
  Formats a Corrosion timestamp (uhlc NTP64 format) to readable format.
  
  Delegates to CorroCLI.TimeUtils.format_corrosion_timestamp/1.
  """
  def format_corrosion_timestamp(ntp64_timestamp) do
    CorroCLI.TimeUtils.format_corrosion_timestamp(ntp64_timestamp)
  end

  @doc """
  Convenience function to get human-readable member summary.
  
  Delegates to CorroCLI.Parser.summarize_member/1.
  """
  def summarize_member(member) do
    CorroCLI.Parser.summarize_member(member)
  end

  @doc """
  Helper function to check if a member appears to be actively participating in the cluster.
  
  Delegates to CorroCLI.Parser.active_member?/1.
  """
  def active_member?(member) do
    CorroCLI.Parser.active_member?(member)
  end

  @doc """
  Extracts region information from cluster members.
  
  Delegates to CorroCLI.Parser.extract_cluster_regions/1.
  """
  def extract_cluster_regions(members) do
    CorroCLI.Parser.extract_cluster_regions(members)
  end

  @doc """
  Extracts region from a node ID.
  
  Delegates to CorroCLI.Parser.extract_region_from_node_id/1.
  """
  def extract_region_from_node_id(node_id) do
    CorroCLI.Parser.extract_region_from_node_id(node_id)
  end
end
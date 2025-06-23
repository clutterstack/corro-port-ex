defmodule CorroPort.CorroCliAdapter do
  @moduledoc """
  Adapter module that wraps the new CorroCLI library to maintain compatibility
  with CorroPort's existing interface.

  This adapter configures the CorroCLI library with CorroPort's node configuration
  and provides the same interface as the original CorroPort.CorroCLI module.
  """

  require Logger
  alias CorroPort.NodeConfig

  @doc """
  Gets cluster members information using `corrosion cluster members`.
  
  Delegates to CorroCLI with CorroPort's configuration.
  """
  def cluster_members(opts \\ []) do
    opts = merge_node_config(opts)
    CorroCLI.cluster_members(opts)
  end

  @doc """
  Gets cluster members information asynchronously.
  """
  def cluster_members_async(opts \\ []) do
    opts = merge_node_config(opts)
    CorroCLI.cluster_members_async(opts)
  end

  @doc """
  Gets cluster information using `corrosion cluster info`.
  """
  def cluster_info(opts \\ []) do
    opts = merge_node_config(opts)
    CorroCLI.cluster_info(opts)
  end

  @doc """
  Gets cluster information asynchronously.
  """
  def cluster_info_async(opts \\ []) do
    opts = merge_node_config(opts)
    CorroCLI.cluster_info_async(opts)
  end

  @doc """
  Gets cluster status using `corrosion cluster status`.
  """
  def cluster_status(opts \\ []) do
    opts = merge_node_config(opts)
    CorroCLI.cluster_status(opts)
  end

  @doc """
  Gets cluster status asynchronously.
  """
  def cluster_status_async(opts \\ []) do
    opts = merge_node_config(opts)
    CorroCLI.cluster_status_async(opts)
  end

  @doc """
  Runs an arbitrary corrosion command with CorroPort's node configuration.
  """
  def run_command(args, opts \\ []) when is_list(args) do
    opts = merge_node_config(opts)
    CorroCLI.run_command(args, opts)
  end

  @doc """
  Runs an arbitrary corrosion command asynchronously.
  """
  def run_command_async(args, opts \\ []) when is_list(args) do
    opts = merge_node_config(opts)
    CorroCLI.run_command_async(args, opts)
  end

  # Private function to merge CorroPort's node configuration with provided options
  defp merge_node_config(opts) do
    # Get paths from NodeConfig if not provided in opts
    default_opts = [
      binary_path: NodeConfig.get_corro_binary_path(),
      config_path: NodeConfig.get_config_path()
    ]

    # Merge with provided opts, giving priority to explicitly passed options
    Keyword.merge(default_opts, opts)
  end
end
defmodule CorroPort.CorroGenserver do
  use GenServer
  require Logger

  alias CorroPort.NodeConfig

  @moduledoc """
  Manages a Corrosion database instance via Elixir Ports.

  Started from Tony Collen's example at
  https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/.
  """

  @command "corrosion/corrosion-mac"
  @wrapper "corrosion/wrapper.sh"

  # GenServer API
  def start_link(args \\ [], opts \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(opts, :name, __MODULE__))
  end

  def init(args \\ []) do
    Process.flag(:trap_exit, true)

    # Generate and write the node-specific Corrosion config
    case NodeConfig.write_corrosion_config() do
      {:ok, config_path} ->
        Logger.info("Generated Corrosion config: #{config_path}")
        start_corrosion_process(config_path)

      {:error, reason} ->
        Logger.error("Failed to generate Corrosion config: #{reason}")
        {:stop, reason}
    end
  end

  defp start_corrosion_process(config_path) do
    node_id = NodeConfig.get_corrosion_node_id()

    # Ensure admin socket directory exists
    File.mkdir_p!("/tmp/corrosion")

    Logger.info("Starting Corrosion for #{node_id} with config: #{config_path}")

    # Start Corrosion with the generated config - add :binary option for proper string output
    port_args = [@command, "agent", "-c", config_path]
    port = Port.open({:spawn_executable, @wrapper},
      [:binary, :exit_status, args: port_args]  # :binary ensures we get strings, not char lists
    )
    Port.monitor(port)

    {:ok, %{
      port: port,
      latest_output: nil,
      exit_status: nil,
      node_id: node_id,
      config_path: config_path
    }}
  end

  def terminate(reason, %{port: port, node_id: node_id} = state) do
    Logger.info("** TERMINATE #{node_id}: #{inspect(reason)}. Cleaning up Corrosion process.")
    Logger.info("Final state: #{inspect(state)}")

    # Try to get port info before it's closed
    case Port.info(port) do
      nil ->
        Logger.info("Port already closed for #{node_id}")
      port_info ->
        os_pid = port_info[:os_pid]
        Logger.warning("Cleaning up orphaned OS process for #{node_id}: #{os_pid}")

        # Send TERM signal first, then KILL if needed
        try do
          System.cmd("kill", ["-TERM", "#{os_pid}"])
          Process.sleep(1000)  # Give it a moment to terminate gracefully
          System.cmd("kill", ["-KILL", "#{os_pid}"])
        catch
          _ -> Logger.info("Process #{os_pid} already terminated")
        end
    end

    :normal
  end

  # This callback handles data incoming from Corrosion's STDOUT
  # With :binary option, data should now be a proper string
  def handle_info({port, {:data, text_line}}, %{port: port, node_id: node_id} = state) when is_binary(text_line) do
    Logger.warning("[#{node_id}] #{text_line}")
    {:noreply, %{state | latest_output: text_line}}
  end

  # Fallback for any remaining char list data (shouldn't happen with :binary)
  def handle_info({port, {:data, data}}, %{port: port, node_id: node_id} = state) do
    text_line = case data do
      bytes when is_list(bytes) -> List.to_string(bytes)
      other -> inspect(other)
    end

    Logger.warning("[#{node_id}] #{text_line}")
    {:noreply, %{state | latest_output: text_line}}
  end

  # This callback tells us when the Corrosion process exits
  def handle_info({port, {:exit_status, status}}, %{port: port, node_id: node_id} = state) do
    Logger.info("#{node_id} port exit: :exit_status: #{status}")
    new_state = %{state | exit_status: status}
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :port, port, :normal}, %{node_id: node_id} = state) do
    Logger.info("Handled :DOWN message from #{node_id} port: #{inspect(port)}")
    {:noreply, state}
  end

  def handle_info({:EXIT, port, :normal}, %{node_id: node_id} = state) do
    Logger.info("#{node_id} handle_info: EXIT")
    {:noreply, state}
  end

  def handle_info(msg, %{node_id: node_id} = state) do
    Logger.info("#{node_id} unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Public API for getting node status
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      node_id: state.node_id,
      config_path: state.config_path,
      latest_output: state.latest_output,
      exit_status: state.exit_status,
      port_info: (if state.port, do: Port.info(state.port), else: nil)
    }
    {:reply, status, state}
  end
end

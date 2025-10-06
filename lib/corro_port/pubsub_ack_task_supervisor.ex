defmodule CorroPort.PubSubAckTaskSupervisor do
  @moduledoc """
  Thin wrapper around `Task.Supervisor` so we have a named child spec for
  acknowledgment HTTP work.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    Task.Supervisor.child_spec(opts)
  end
end
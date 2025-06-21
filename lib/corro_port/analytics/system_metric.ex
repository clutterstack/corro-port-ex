defmodule CorroPort.Analytics.SystemMetric do
  @moduledoc """
  Ecto schema for system performance metrics.
  
  Records CPU, memory, and Erlang VM metrics over time
  for correlation with message propagation performance.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  schema "system_metrics" do
    field :experiment_id, :string
    field :node_id, :string
    field :cpu_percent, :float
    field :memory_mb, :integer
    field :erlang_processes, :integer
    field :corrosion_connections, :integer
    field :message_queue_length, :integer
    
    timestamps(type: :utc_datetime, updated_at: false)
  end
  
  def changeset(metric, attrs) do
    metric
    |> cast(attrs, [:experiment_id, :node_id, :cpu_percent, :memory_mb, :erlang_processes, :corrosion_connections, :message_queue_length])
    |> validate_required([:experiment_id, :node_id])
    |> validate_length(:experiment_id, min: 1)
    |> validate_length(:node_id, min: 1)
    |> validate_number(:cpu_percent, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> validate_number(:memory_mb, greater_than_or_equal_to: 0)
    |> validate_number(:erlang_processes, greater_than_or_equal_to: 0)
    |> validate_number(:corrosion_connections, greater_than_or_equal_to: 0)
    |> validate_number(:message_queue_length, greater_than_or_equal_to: 0)
  end
end
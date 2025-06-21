defmodule CorroPort.Analytics.TopologySnapshot do
  @moduledoc """
  Ecto schema for topology snapshots during experiments.
  
  Captures the bootstrap configuration and experimental parameters
  for each node at the start of an experiment run.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  schema "topology_snapshots" do
    field :experiment_id, :string
    field :node_id, :string
    field :bootstrap_peers, {:array, :string}
    field :transaction_size_bytes, :integer
    field :transaction_frequency_ms, :integer
    
    timestamps(type: :utc_datetime)
  end
  
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:experiment_id, :node_id, :bootstrap_peers, :transaction_size_bytes, :transaction_frequency_ms])
    |> validate_required([:experiment_id, :node_id, :bootstrap_peers])
    |> validate_length(:experiment_id, min: 1)
    |> validate_length(:node_id, min: 1)
    |> validate_number(:transaction_size_bytes, greater_than: 0)
    |> validate_number(:transaction_frequency_ms, greater_than: 0)
  end
end
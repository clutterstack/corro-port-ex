defmodule CorroPort.Analytics.Repo.Migrations.CreateAnalyticsTables do
  use Ecto.Migration

  def change do
    create table(:topology_snapshots) do
      add :experiment_id, :string, null: false
      add :node_id, :string, null: false
      add :bootstrap_peers, {:array, :string}, null: false
      add :transaction_size_bytes, :integer
      add :transaction_frequency_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:topology_snapshots, [:experiment_id])
    create index(:topology_snapshots, [:node_id])

    create table(:message_events) do
      add :message_id, :string, null: false
      add :experiment_id, :string, null: false
      add :originating_node, :string, null: false
      add :target_node, :string
      add :event_type, :string, null: false
      add :region, :string
      add :transaction_size_hint, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:message_events, [:experiment_id])
    create index(:message_events, [:message_id])
    create index(:message_events, [:event_type])
    create index(:message_events, [:inserted_at])

    create table(:system_metrics) do
      add :experiment_id, :string, null: false
      add :node_id, :string, null: false
      add :cpu_percent, :float
      add :memory_mb, :integer
      add :erlang_processes, :integer
      add :corrosion_connections, :integer
      add :message_queue_length, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:system_metrics, [:experiment_id])
    create index(:system_metrics, [:node_id])
    create index(:system_metrics, [:inserted_at])
  end
end
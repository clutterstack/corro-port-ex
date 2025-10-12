defmodule CorroPort.Analytics.Repo.Migrations.AddEventTimestampToMessageEvents do
  use Ecto.Migration

  def change do
    alter table(:message_events) do
      # Add as nullable first since we have existing data
      add :event_timestamp, :utc_datetime_usec
    end

    # Backfill existing rows with inserted_at timestamp
    execute(
      "UPDATE message_events SET event_timestamp = inserted_at WHERE event_timestamp IS NULL",
      "-- no rollback needed"
    )
  end
end

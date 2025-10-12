defmodule CorroPort.Analytics.Repo.Migrations.AddReceiptTimestampToMessageEvents do
  use Ecto.Migration

  def change do
    alter table(:message_events) do
      add :receipt_timestamp, :utc_datetime_usec
    end
  end
end

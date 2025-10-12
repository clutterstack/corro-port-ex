defmodule CorroPort.Analytics.MessageEvent do
  @moduledoc """
  Ecto schema for message timing events.

  Records precise timing of message send and acknowledgment events
  with experimental context for performance analysis.

  ## Timestamp Fields

  - `event_timestamp` - When the event occurred (message sent or ack received)
  - `receipt_timestamp` - When the message was first received via gossip (acks only)
  - `inserted_at` - When this event was recorded in the database
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "message_events" do
    field(:message_id, :string)
    field(:experiment_id, :string)
    field(:originating_node, :string)
    field(:target_node, :string)
    field(:event_type, Ecto.Enum, values: [:sent, :acked])
    field(:event_timestamp, :utc_datetime_usec)
    field(:receipt_timestamp, :utc_datetime_usec)
    field(:region, :string)
    field(:transaction_size_hint, :integer)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :message_id,
      :experiment_id,
      :originating_node,
      :target_node,
      :event_type,
      :event_timestamp,
      :receipt_timestamp,
      :region,
      :transaction_size_hint
    ])
    |> validate_required([:message_id, :experiment_id, :originating_node, :event_type, :event_timestamp])
    |> validate_length(:message_id, min: 1)
    |> validate_length(:experiment_id, min: 1)
    |> validate_length(:originating_node, min: 1)
    |> validate_inclusion(:event_type, [:sent, :acked])
  end
end

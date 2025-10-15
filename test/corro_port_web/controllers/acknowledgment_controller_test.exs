defmodule CorroPortWeb.AcknowledgmentControllerTest do
  use CorroPortWeb.ConnCase, async: false

  alias CorroPort.{AckTracker, Analytics}
  alias CorroPort.Analytics.Repo

  @migrations_path Application.app_dir(:corro_port, "priv/analytics_repo/migrations")

  setup_all do
    # Ensure analytics tables (including receipt timestamps) exist for tests
    {:ok, _, _} = Ecto.Migrator.with_repo(Repo, fn repo -> Ecto.Migrator.run(repo, @migrations_path, :up, all: true) end)

    ack_pid =
      case Process.whereis(AckTracker) do
        nil -> start_supervised!({AckTracker, []})
        pid -> pid
      end

    :ok = AckTracker.reset_tracking()

    {:ok, ack_pid: ack_pid}
  end

  setup %{ack_pid: ack_pid, conn: conn} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), ack_pid)

    experiment_id = "pubsub_receipt_test"
    message_id = "pubsub_msg_#{System.unique_integer([:positive])}"

    :ok = AckTracker.reset_tracking()
    :ok = AckTracker.set_experiment_id(experiment_id)

    # Seed tracker with the message we expect acknowledgments for
    :ok =
      AckTracker.track_latest_message(%{
        pk: message_id,
        node_id: "origin-node",
        timestamp: DateTime.utc_now(),
        experiment_id: experiment_id
      })

    {:ok, conn: conn, experiment_id: experiment_id, message_id: message_id}
  end

  describe "acknowledge_pubsub/2" do
    test "records receipt timestamps for pubsub acknowledgments", %{
      conn: conn,
      experiment_id: experiment_id,
      message_id: message_id
    } do
      receipt_ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      payload = %{
        "request_id" => message_id,
        "ack_node_id" => "ack-node-1",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "receipt_timestamp" => DateTime.to_iso8601(receipt_ts)
      }

      response =
        conn
        |> post(~p"/api/acknowledge_pubsub", payload)
        |> json_response(200)

      assert response["status"] == "acknowledged"
      assert response["receipt_timestamp"] == DateTime.to_iso8601(receipt_ts)

      events = Analytics.get_message_events(experiment_id, event_type: :acked)
      assert length(events) == 1

      ack_event = hd(events)
      assert ack_event.message_id == message_id
      assert DateTime.compare(ack_event.receipt_timestamp, receipt_ts) == :eq
      assert ack_event.event_type == :acked
    end
  end
end

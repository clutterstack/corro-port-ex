defmodule CorroPortWeb.AckEndpoint do
  @moduledoc """
  Minimal Phoenix endpoint for handling acknowledgment API requests.

  This endpoint runs on a separate port and handles only acknowledgment
  traffic between nodes. No web UI, sessions, or static files.
  """

  use Phoenix.Endpoint, otp_app: :corro_port

  # Minimal plug pipeline for API-only endpoint
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :ack_endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug CorroPortWeb.AckRouter
end

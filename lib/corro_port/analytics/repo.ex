defmodule CorroPort.Analytics.Repo do
  use Ecto.Repo,
    otp_app: :corro_port,
    adapter: Ecto.Adapters.SQLite3
end
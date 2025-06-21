ExUnit.start()

# Start the Analytics Repo for tests if not already started
case CorroPort.Analytics.Repo.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# Run migrations for test database
Ecto.Adapters.SQL.Sandbox.mode(CorroPort.Analytics.Repo, :manual)

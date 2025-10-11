defmodule CorroPort.Release do
  @moduledoc false

  @app :corro_port

  def migrate do
    load_app()

    for repo <- repos() do
      prepare_storage(repo)

      {:ok, _pid, _apps} = Ecto.Migrator.with_repo(repo, &run_migrations/1)
    end
  end

  defp run_migrations(repo) do
    Ecto.Migrator.run(repo, :up, all: true)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp prepare_storage(repo) do
    config = repo.config

    with database when is_binary(database) <- config[:database] do
      database
      |> Path.dirname()
      |> File.mkdir_p!()
    end

    case repo.__adapter__().storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "Could not create #{inspect(repo)} storage: #{inspect(reason)}"
    end
  end
end

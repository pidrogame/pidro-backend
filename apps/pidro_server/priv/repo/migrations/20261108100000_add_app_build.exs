defmodule PidroServer.Repo.Migrations.AddAppBuild do
  use Ecto.Migration

  # The native build (iOS build number, Android version code) beside the
  # version: one version now ships as several builds.
  def change do
    alter table(:seat_events) do
      add :app_build, :string
    end

    alter table(:connection_games) do
      add :app_build, :string
    end

    alter table(:push_tokens) do
      add :app_build, :string
    end
  end
end

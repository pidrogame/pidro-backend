defmodule PidroServer.Repo.Migrations.AddClientBuildToSeatEvents do
  use Ecto.Migration

  def change do
    alter table(:seat_events) do
      add :app_version, :string
      add :platform, :string
    end
  end
end

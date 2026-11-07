defmodule PidroServer.Repo.Migrations.CreateAppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :jsonb, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end

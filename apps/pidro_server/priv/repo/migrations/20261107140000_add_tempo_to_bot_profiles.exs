defmodule PidroServer.Repo.Migrations.AddTempoToBotProfiles do
  use Ecto.Migration

  def change do
    alter table(:bot_profiles) do
      add :tempo, :string, null: false, default: "steady"
    end

    create constraint(:bot_profiles, :supported_tempo,
             check: "tempo IN ('quick', 'steady', 'slow')"
           )
  end
end

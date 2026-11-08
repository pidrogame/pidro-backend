defmodule PidroServer.Repo.Migrations.AddHomeAndLinesToBotProfiles do
  use Ecto.Migration

  def change do
    alter table(:bot_profiles) do
      add :home, :string, null: false, default: "anywhere"
      add :lines, {:array, :string}, null: false, default: []
    end

    create constraint(:bot_profiles, :supported_home,
             check: "home IN ('anywhere', 'finland', 'louisiana')"
           )
  end
end

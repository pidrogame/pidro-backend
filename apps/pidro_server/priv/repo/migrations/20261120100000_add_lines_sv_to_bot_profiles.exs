defmodule PidroServer.Repo.Migrations.AddLinesSvToBotProfiles do
  use Ecto.Migration

  def change do
    alter table(:bot_profiles) do
      add :lines_sv, {:array, :string}, null: false, default: []
    end
  end
end

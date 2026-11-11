defmodule PidroServer.Repo.Migrations.CreateClassicPremiumCarryovers do
  use Ecto.Migration

  def change do
    create table(:classic_premium_carryovers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :classic_user_id, :bigint, null: false
      add :state, :string, null: false
      add :classic_premium_until, :utc_datetime
      add :attempts, :integer, null: false, default: 0
      add :last_error, :string
      add :last_tried_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:classic_premium_carryovers, [:user_id])

    create constraint(:classic_premium_carryovers, :classic_premium_state_is_valid,
             check: "state IN ('pending', 'granted', 'imported', 'ended', 'none')"
           )
  end
end

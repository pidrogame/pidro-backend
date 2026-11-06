defmodule PidroServer.Repo.Migrations.CreateConnectionTableOutcomes do
  use Ecto.Migration

  def change do
    create table(:connection_table_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :game_instance_id, :string, null: false
      add :turns, :integer, null: false
      add :bot_turns, :integer, null: false
      add :others_finished, :boolean
      add :cohorts, {:array, :map}, null: false
      timestamps()
    end

    create unique_index(:connection_table_outcomes, [:game_instance_id])
    create index(:connection_table_outcomes, [:inserted_at])
  end
end

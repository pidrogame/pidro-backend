defmodule PidroServer.Repo.Migrations.CreateConnectionGames do
  use Ecto.Migration

  def change do
    create table(:connection_games, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :room_id, :string, null: false
      add :room_code, :string, null: false
      add :game_instance_id, :string, null: false
      add :checks_sent, :integer, null: false
      add :unanswered_checks, :integer, null: false
      add :median_ms, :float
      add :p95_ms, :float
      add :rtt_histogram, :map, null: false, default: %{}
      add :drops, :integer, null: false
      add :disconnected_seconds, :float, null: false
      add :duration_seconds, :float, null: false
      add :app_version, :string
      add :platform, :string
      add :network, :string
      add :network_ms, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:connection_games, [:user_id, :game_instance_id])
    create index(:connection_games, [:inserted_at])
  end
end

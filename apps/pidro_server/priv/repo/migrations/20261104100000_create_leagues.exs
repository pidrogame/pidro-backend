defmodule PidroServer.Repo.Migrations.CreateLeagues do
  use Ecto.Migration

  def change do
    create table(:league_players, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :league, :text, null: false, default: "deuce"
      add :hidden, :boolean, null: false, default: false
      add :intro_seen, :boolean, null: false, default: false
    end

    create table(:league_weeks, primary_key: false) do
      add :closes_at, :utc_datetime, primary_key: true
    end

    create table(:league_rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :league, :text, null: false
      add :starts_at, :utc_datetime, null: false
      add :closes_at, :utc_datetime, null: false
      add :closed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:league_rooms, [:closes_at, :league])

    create table(:league_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :room_id, references(:league_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :closes_at, :utc_datetime, null: false
      add :points, :integer, null: false, default: 0
      add :points_at, :utc_datetime_usec, null: false
      add :placed_at, :utc_datetime_usec, null: false
    end

    create unique_index(:league_memberships, [:closes_at, :user_id])
    create index(:league_memberships, [:room_id])
    create index(:league_memberships, [:user_id])

    create table(:league_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # History survives account deletion, like game_xp and game_stats.
      add :user_id, :binary_id, null: false
      add :week_starts_at, :utc_datetime, null: false
      add :week_closes_at, :utc_datetime, null: false
      add :old_league, :text, null: false
      add :new_league, :text, null: false
      add :move, :text, null: false
      add :place, :integer, null: false
      add :points, :integer, null: false
      add :room_size, :integer, null: false
      add :seen_at, :utc_datetime_usec
      add :ribbon, :map
    end

    create unique_index(:league_results, [:week_closes_at, :user_id])
    create index(:league_results, [:user_id, :week_closes_at])

    for table <- [:league_players, :league_rooms] do
      create constraint(table, :valid_league,
               check: "league IN ('deuce', 'ten', 'jack', 'ace', 'pidro')"
             )
    end
  end
end

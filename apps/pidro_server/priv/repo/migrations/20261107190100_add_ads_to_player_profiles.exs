defmodule PidroServer.Repo.Migrations.AddAdsToPlayerProfiles do
  use Ecto.Migration

  def change do
    alter table(:player_profiles) do
      add :solo_games_started, :integer, null: false, default: 0
      add :ad_credit_expires_at, :utc_datetime_usec
    end

    create table(:ad_events) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      # Set on `offered` only: the solo count the offer was for.
      add :solo_games_started, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:ad_events, :supported_kind,
             check: "kind IN ('offered', 'watched', 'unavailable', 'dismissed')"
           )

    create index(:ad_events, [:inserted_at])
    # Deleting a user deletes their events.
    create index(:ad_events, [:user_id])

    # One offer per needed game, however often /me is polled.
    create unique_index(:ad_events, [:user_id, :solo_games_started],
             where: "kind = 'offered'",
             name: :ad_events_one_offer_per_game
           )
  end
end

defmodule PidroServer.Repo.Migrations.CreateEntitlements do
  use Ecto.Migration

  def change do
    create table(:entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :entitlement, :string, null: false
      add :active, :boolean, null: false, default: false
      add :expires_at, :utc_datetime
      add :product_id, :string
      add :store, :string
      add :source, :string, null: false
      add :rc_original_app_user_id, :string
      add :last_event_id, :string
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:entitlements, [:user_id, :entitlement])

    create constraint(:entitlements, :entitlement_source_is_valid,
             check: "source IN ('store', 'promotional', 'classic_honored')"
           )

    create table(:revenuecat_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :string, null: false
      add :type, :string, null: false
      add :app_user_id, :string
      add :payload, :map, null: false
      add :processed_at, :utc_datetime
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:revenuecat_events, [:event_id])
    create index(:revenuecat_events, [:app_user_id])
  end
end

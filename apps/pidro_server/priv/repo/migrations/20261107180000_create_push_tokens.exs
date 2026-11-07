defmodule PidroServer.Repo.Migrations.CreatePushTokens do
  use Ecto.Migration

  # Expo push (PID-392): one row per phone, and one per message Expo accepted
  # until its receipt is read. Deleting the account deletes both.
  def change do
    create table(:push_tokens) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :platform, :string, null: false
      add :install_id, :string
      add :app_version, :string
      add :last_used_at, :utc_datetime_usec
      add :disabled_at, :utc_datetime_usec
      add :disabled_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:push_tokens, [:token])
    create index(:push_tokens, [:user_id])

    create table(:push_tickets) do
      add :token_id, references(:push_tokens, on_delete: :delete_all), null: false
      add :ticket_id, :string, null: false
      add :title, :string
      add :sent_at, :utc_datetime_usec, null: false
      add :receipt_status, :string
      add :receipt_error, :string
      add :checked_at, :utc_datetime_usec
    end

    create unique_index(:push_tickets, [:ticket_id])
    create index(:push_tickets, [:token_id])
    create index(:push_tickets, [:sent_at], where: "checked_at IS NULL")
  end
end

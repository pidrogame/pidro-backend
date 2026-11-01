defmodule PidroServer.Repo.Migrations.CreateFeedback do
  use Ecto.Migration

  # The bigserial id is the ticket number players and support see (PID-316).
  def change do
    create table(:feedback) do
      add :kind, :string, null: false
      add :body, :text
      add :answer, :string
      add :user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :reply_email, :string
      add :game_id, :uuid
      add :rule_set, :string
      add :details, :map, null: false, default: %{}
      add :status, :string, null: false, default: "open"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:feedback, [:user_id, :kind])
  end
end

defmodule PidroServer.Repo.Migrations.CreateEmailSends do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :update_emails_off_at, :utc_datetime
    end

    create table(:email_sends, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :template_id,
          references(:email_templates, type: :binary_id, on_delete: :nilify_all)

      add :template, :map, null: false
      add :started_by, :string, null: false
      add :state, :string, null: false
      add :paused_reason, :string
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_sends, [:template_id])

    # One mailing at a time, also across the two containers of a deploy.
    create unique_index(:email_sends, [:state],
             where: "state = 'running'",
             name: :email_sends_one_running
           )

    create constraint(:email_sends, :email_send_state_is_valid,
             check: "state IN ('running', 'paused', 'finished')"
           )

    create table(:email_send_recipients) do
      add :send_id, references(:email_sends, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_send_recipients, [:send_id, :user_id])
    create index(:email_send_recipients, [:send_id, :state, :id])
    create index(:email_send_recipients, [:user_id])

    create constraint(:email_send_recipients, :email_send_recipient_state_is_valid,
             check: "state IN ('pending', 'claimed', 'sent', 'failed', 'skipped')"
           )
  end
end

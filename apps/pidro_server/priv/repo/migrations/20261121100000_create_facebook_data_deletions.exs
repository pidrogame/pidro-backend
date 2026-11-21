defmodule PidroServer.Repo.Migrations.CreateFacebookDataDeletions do
  use Ecto.Migration

  def change do
    create table(:facebook_data_deletions, primary_key: false) do
      add :code, :string, primary_key: true
      add :outcome, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:facebook_data_deletions, :facebook_data_deletion_outcome_is_valid,
             check: "outcome IN ('deleted', 'no_account')"
           )
  end
end

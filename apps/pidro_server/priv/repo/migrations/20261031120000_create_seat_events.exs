defmodule PidroServer.Repo.Migrations.CreateSeatEvents do
  use Ecto.Migration

  def change do
    create table(:seat_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :room_code, :string, null: false
      add :kind, :string, null: false
      add :elapsed_ms, :integer

      timestamps(updated_at: false)
    end

    create index(:seat_events, [:inserted_at])
  end
end

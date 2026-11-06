defmodule PidroServer.Repo.Migrations.AddConnectionContextToSeatEvents do
  use Ecto.Migration

  def change do
    alter table(:seat_events) do
      add :reason, :string
      add :network, :string
    end
  end
end

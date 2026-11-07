defmodule PidroServer.Repo.Migrations.AddMetadataToSeatEvents do
  use Ecto.Migration

  def change do
    alter table(:seat_events) do
      add :metadata, :map
    end
  end
end

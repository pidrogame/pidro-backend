defmodule PidroServer.Repo.Migrations.CreateLiveRooms do
  use Ecto.Migration

  # One row per open room: the node that owns it, fenced by an epoch, and what
  # a new node needs to bring the room back after a deploy.
  def change do
    create table(:live_rooms, primary_key: false) do
      add :code, :text, primary_key: true
      add :owner, :text
      add :epoch, :bigint, null: false
      add :heartbeat_at, :utc_datetime_usec, null: false
      add :game_instance_id, :text
      add :room, :map
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:live_rooms, [:owner])
  end
end

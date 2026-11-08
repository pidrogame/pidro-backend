defmodule PidroServer.Repo.Migrations.AddAvatarFaceToUsers do
  use Ecto.Migration

  # The face a player without a photo picked, "a" or "b" (PID-395). Null
  # means never picked, and the apps draw their own fallback.
  def change do
    alter table(:users) do
      add :avatar_face, :string
    end
  end
end

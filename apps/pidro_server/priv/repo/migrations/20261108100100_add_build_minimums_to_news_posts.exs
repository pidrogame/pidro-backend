defmodule PidroServer.Repo.Migrations.AddBuildMinimumsToNewsPosts do
  use Ecto.Migration

  # With a version, an app-update post can also nudge that version's older builds.
  def change do
    alter table(:news_posts) do
      add :show_below_android_build, :string
      add :show_below_ios_build, :string
    end
  end
end

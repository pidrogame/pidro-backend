defmodule PidroServer.Repo.Migrations.CreateNewsPosts do
  use Ecto.Migration

  # News posts we write in admin (PID-346). A null published_at is a draft;
  # Swedish falls back to English per field. A player's news_seen_at marks
  # what they have read, and a note can answer a post.
  def change do
    create table(:news_posts) do
      add :title_en, :string, null: false
      add :body_en, :text, null: false
      add :title_sv, :string
      add :body_sv, :text
      add :published_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create index(:news_posts, [:published_at])

    alter table(:users) do
      add :news_seen_at, :utc_datetime
    end

    alter table(:feedback) do
      add :news_post_id, references(:news_posts, on_delete: :nilify_all)
    end

    create index(:feedback, [:news_post_id])
  end
end

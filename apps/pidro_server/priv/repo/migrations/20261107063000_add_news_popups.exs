defmodule PidroServer.Repo.Migrations.AddNewsPopups do
  use Ecto.Migration

  def change do
    alter table(:news_posts) do
      add :eyebrow_en, :string
      add :eyebrow_sv, :string
      add :button_label_en, :string
      add :button_label_sv, :string
      add :button_url, :text
      add :show_as_popup, :boolean, null: false, default: false
      add :app_update, :boolean, null: false, default: false
      add :show_below_android, :string
      add :show_below_ios, :string
      add :image, :binary
      add :image_version, :string
    end

    create table(:news_popup_receipts, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true
      add :post_id, references(:news_posts, on_delete: :delete_all), primary_key: true
      add :seen_at, :utc_datetime, null: false
    end

    create index(:news_popup_receipts, [:post_id])
  end
end

defmodule PidroServer.News.Post do
  @moduledoc """
  A news post we write in admin, in English and optionally Swedish. A null
  `published_at` is a draft. `answers` counts the notes written back to it,
  when the query selects it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "news_posts" do
    field :title_en, :string
    field :body_en, :string
    field :title_sv, :string
    field :body_sv, :string
    field :published_at, :utc_datetime
    field :answers, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The texts admin edits; the English ones are required."
  def changeset(post, params) do
    post
    |> cast(params, [:title_en, :body_en, :title_sv, :body_sv])
    |> validate_required([:title_en, :body_en])
    |> validate_length(:title_en, max: 200)
    |> validate_length(:title_sv, max: 200)
    |> validate_length(:body_en, max: 5_000)
    |> validate_length(:body_sv, max: 5_000)
  end
end

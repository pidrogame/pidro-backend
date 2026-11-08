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
    field :eyebrow_en, :string
    field :eyebrow_sv, :string
    field :button_label_en, :string
    field :button_label_sv, :string
    field :button_url, :string
    field :show_as_popup, :boolean, default: false
    field :app_update, :boolean, default: false
    field :show_below_android, :string
    field :show_below_ios, :string
    field :show_below_android_build, :string
    field :show_below_ios_build, :string
    field :image, :binary, load_in_query: false
    field :image_version, :string
    field :published_at, :utc_datetime
    field :answers, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The texts admin edits; the English ones are required."
  def changeset(post, params) do
    post
    |> cast(params, [
      :title_en,
      :body_en,
      :title_sv,
      :body_sv,
      :eyebrow_en,
      :eyebrow_sv,
      :button_label_en,
      :button_label_sv,
      :button_url,
      :show_as_popup,
      :app_update,
      :show_below_android,
      :show_below_ios,
      :show_below_android_build,
      :show_below_ios_build
    ])
    |> validate_required([:title_en, :body_en])
    |> validate_length(:title_en, max: 200)
    |> validate_length(:title_sv, max: 200)
    |> validate_length(:body_en, max: 5_000)
    |> validate_length(:body_sv, max: 5_000)
    |> validate_length(:eyebrow_en, max: 200)
    |> validate_length(:eyebrow_sv, max: 200)
    |> validate_length(:button_label_en, max: 100)
    |> validate_length(:button_label_sv, max: 100)
    |> validate_length(:button_url, max: 2_000)
    |> validate_change(:button_url, fn field, url ->
      if safe_link?(url), do: [], else: [{field, "must be an http, https or pidro link"}]
    end)
    |> validate_change(:show_below_android, &validate_version/2)
    |> validate_change(:show_below_ios, &validate_version/2)
    |> validate_build(:show_below_android_build, :show_below_android)
    |> validate_build(:show_below_ios_build, :show_below_ios)
  end

  @doc "Only web and app links may be opened from News."
  def safe_link?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ~w(http https pidro) and is_binary(uri.host) and uri.host != "" and
      not String.match?(url, ~r/[\s<>]/u)
  end

  def safe_link?(_), do: false

  # A build only narrows its own version: 3.3.0 build 15 also nudges 3.3.0 (14).
  defp validate_build(changeset, field, version) do
    changeset
    |> validate_format(field, ~r/\A\d{1,10}\z/, message: "must be a build number like 15")
    |> then(fn changeset ->
      if get_field(changeset, field) && is_nil(get_field(changeset, version)),
        do: add_error(changeset, field, "needs a version beside it"),
        else: changeset
    end)
  end

  defp validate_version(field, value) do
    if String.match?(value, ~r/\A\d+\.\d+\.\d+\z/) and match?({:ok, _}, Version.parse(value)),
      do: [],
      else: [{field, "must be a version like 3.2.4"}]
  end
end

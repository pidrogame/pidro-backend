defmodule PidroServer.News do
  @moduledoc """
  News posts (PID-346): written and published in `/admin/news`, read by
  every player's app in English or Swedish. A post is new to a player when
  it was published after their `news_seen_at`. A note can answer a post,
  through `PidroServer.Feedback`.
  """

  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.Feedback.Entry
  alias PidroServer.News.Post
  alias PidroServer.Repo

  @doc """
  The latest `limit` published posts, newest first, as the app shows them:
  `%{id, title, body, published_at}` in `locale` (`"en"` or `"sv"`). Swedish
  falls back to English per field.
  """
  @spec list_published(String.t(), pos_integer()) :: [map()]
  def list_published(locale, limit \\ 30) do
    from(p in published(), order_by: [desc: p.published_at, desc: p.id], limit: ^limit)
    |> Repo.all()
    |> Enum.map(&localize(&1, locale))
  end

  @doc "A post's title and body in `locale`, Swedish falling back to English per field."
  @spec localize(Post.t(), String.t()) :: map()
  def localize(post, "sv") do
    %{
      localize(post, "en")
      | title: post.title_sv || post.title_en,
        body: post.body_sv || post.body_en,
        eyebrow: post.eyebrow_sv || post.eyebrow_en,
        button_label: if(!post.app_update, do: post.button_label_sv || post.button_label_en)
    }
  end

  def localize(post, _locale),
    do: %{
      id: post.id,
      title: post.title_en,
      body: post.body_en,
      published_at: post.published_at,
      eyebrow: post.eyebrow_en,
      image_url: image_url(post),
      button_label: if(!post.app_update, do: post.button_label_en),
      button_url: if(!post.app_update, do: post.button_url),
      show_as_popup: post.show_as_popup,
      app_update: post.app_update,
      show_below_android: post.show_below_android,
      show_below_ios: post.show_below_ios,
      show_below_android_build: post.show_below_android_build,
      show_below_ios_build: post.show_below_ios_build
    }

  @doc """
  Newest published, unseen pop-up eligible for this phone; independent of
  feed reads. `build` is the native build; an app that sends none is
  compared by version only.
  """
  def popup(%User{id: user_id}, locale, platform, version, build \\ nil) do
    user_id = Ecto.UUID.dump!(user_id)

    from(p in published(),
      left_join: r in "news_popup_receipts",
      on: r.post_id == p.id and r.user_id == ^user_id,
      where: p.show_as_popup and is_nil(r.post_id),
      order_by: [desc: p.published_at, desc: p.id]
    )
    |> Repo.all()
    |> Enum.find(&eligible?(&1, platform, version, build))
    |> case do
      nil -> nil
      post -> localize(post, locale)
    end
  end

  @doc "Idempotently acknowledges one published pop-up. Later does not call this."
  def mark_popup_seen(%User{id: user_id}, id) do
    case get_published(id) do
      %Post{show_as_popup: true} ->
        Repo.insert_all(
          "news_popup_receipts",
          [%{user_id: Ecto.UUID.dump!(user_id), post_id: id, seen_at: DateTime.utc_now(:second)}],
          on_conflict: :nothing
        )

        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  The newest published app update owns both platform minimums, including
  empty ones: a version per platform and, where set, a build of that version.
  """
  def native_update_policy do
    Map.delete(native_update_policy_with_source(), :source)
  end

  @doc "The same effective policy with its source for the store-builds admin."
  def native_update_policy_with_source do
    post =
      Repo.one(
        from p in published(),
          where: p.app_update,
          order_by: [desc: p.published_at, desc: p.id],
          limit: 1
      )

    case post do
      nil ->
        %{
          minimum_native_versions:
            Application.get_env(:pidro_server, :minimum_native_versions, %{}),
          minimum_native_builds: %{},
          native_update_popup: false,
          source: "from deploy config"
        }

      post ->
        %{
          minimum_native_versions:
            set(%{"android" => post.show_below_android, "ios" => post.show_below_ios}),
          minimum_native_builds:
            set(%{"android" => post.show_below_android_build, "ios" => post.show_below_ios_build}),
          native_update_popup: post.show_as_popup,
          source: "from the app-update post ‘#{post.title_en}’"
        }
    end
  end

  defp set(minimums), do: Map.reject(minimums, fn {_platform, value} -> is_nil(value) end)

  defp eligible?(%Post{app_update: false}, _platform, _version, _build), do: true

  defp eligible?(post, platform, version, build)
       when platform in ~w(android ios) and is_binary(version) do
    {threshold, threshold_build} =
      if platform == "android",
        do: {post.show_below_android, post.show_below_android_build},
        else: {post.show_below_ios, post.show_below_ios_build}

    with true <- is_binary(threshold),
         {:ok, version} <- Version.parse(version),
         {:ok, threshold} <- Version.parse(threshold) do
      case Version.compare(version, threshold) do
        :lt -> true
        :eq -> below_build?(build, threshold_build)
        :gt -> false
      end
    else
      _ -> false
    end
  end

  defp eligible?(_post, _platform, _version, _build), do: false

  # Same version: only a build on both sides tells them apart.
  defp below_build?(build, threshold) when is_binary(build) and is_binary(threshold) do
    case Integer.parse(build) do
      {build, ""} -> build < String.to_integer(threshold)
      _ -> false
    end
  end

  defp below_build?(_build, _threshold), do: false

  @doc "Public URL for the post's current uploaded image."
  def image_url(%Post{image_version: nil}), do: nil

  def image_url(post),
    do: PidroServerWeb.Endpoint.url() <> "/api/v1/news/#{post.id}/image/#{post.image_version}"

  @doc "Stores an image using the same bounded normalization as profile uploads."
  def put_image(post, upload) do
    with {:ok, image} <- PidroServer.Accounts.Avatars.normalize_upload(upload, :news) do
      post
      |> Ecto.Changeset.change(
        image: image,
        image_version: Base.encode16(:crypto.hash(:sha256, image), case: :lower)
      )
      |> Repo.update()
    end
  end

  def remove_image(post),
    do:
      post
      |> Ecto.Changeset.change(image_version: nil)
      |> Ecto.Changeset.force_change(:image, nil)
      |> Repo.update()

  def fetch_image(id, version) do
    Repo.one(from p in Post, where: p.id == ^id and p.image_version == ^version, select: p.image)
  end

  @doc """
  How many published posts `user` has not seen: all of them before the first
  look. Both times are whole seconds, so a post published in the second of
  the look still counts: a dot once too often, never a post missed.
  """
  @spec unread_count(User.t()) :: non_neg_integer()
  def unread_count(%User{news_seen_at: nil}), do: Repo.aggregate(published(), :count)

  def unread_count(%User{news_seen_at: seen_at}),
    do: published() |> where([p], p.published_at >= ^seen_at) |> Repo.aggregate(:count)

  @doc "Marks every post published so far seen by `user`."
  @spec mark_seen(User.t()) :: :ok
  def mark_seen(%User{id: id}) do
    now = DateTime.utc_now(:second)
    Repo.update_all(from(u in User, where: u.id == ^id), set: [news_seen_at: now])
    :ok
  end

  @doc "Every post with its answer count: drafts first, then published newest first."
  @spec list_all() :: [Post.t()]
  def list_all do
    from(p in Post,
      left_join: f in Entry,
      on: f.news_post_id == p.id and f.kind == "note",
      group_by: p.id,
      order_by: [
        desc: is_nil(p.published_at),
        desc: p.published_at,
        desc: p.id
      ],
      select_merge: %{answers: count(f.id)}
    )
    |> Repo.all()
  end

  @spec get!(integer() | String.t()) :: Post.t()
  def get!(id), do: Repo.get!(Post, id)

  @doc "The published post with `id`, or nil for a draft or a missing or malformed id."
  @spec get_published(term()) :: Post.t() | nil
  def get_published(id) when is_integer(id) and id in 1..9_223_372_036_854_775_807,
    do: Repo.get(published(), id)

  def get_published(_id), do: nil

  @doc "A new draft."
  @spec create(map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def create(params), do: %Post{} |> Post.changeset(params) |> Repo.insert()

  @spec update(Post.t(), map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def update(post, params), do: post |> Post.changeset(params) |> Repo.update()

  @spec change(Post.t(), map()) :: Ecto.Changeset.t()
  def change(post, params \\ %{}), do: Post.changeset(post, params)

  @doc "Publishes a draft now: players see it at once."
  @spec publish(Post.t()) :: {:ok, Post.t()} | {:error, :published}
  def publish(%Post{published_at: nil} = post),
    do: post |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second)) |> Repo.update()

  def publish(%Post{}), do: {:error, :published}

  @doc "Takes a post back to a draft."
  @spec unpublish(Post.t()) :: {:ok, Post.t()}
  def unpublish(post), do: post |> Ecto.Changeset.change(published_at: nil) |> Repo.update()

  @doc "Deletes a draft. A published post is unpublished first."
  @spec delete(Post.t()) :: {:ok, Post.t()} | {:error, :published}
  def delete(%Post{published_at: nil} = post), do: Repo.delete(post)
  def delete(%Post{}), do: {:error, :published}

  defp published, do: from(p in Post, where: not is_nil(p.published_at))
end

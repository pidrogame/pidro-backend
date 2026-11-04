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
        body: post.body_sv || post.body_en
    }
  end

  def localize(post, _locale),
    do: %{id: post.id, title: post.title_en, body: post.body_en, published_at: post.published_at}

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

defmodule PidroServer.Blocks do
  @moduledoc "Reversible blocks and symmetric discovery and admission checks."
  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.Blocks.Block
  alias PidroServer.Friends.{Friendship, Ignore}
  alias PidroServer.Repo

  @doc "Blocks a player and removes friendship and ignores in both directions atomically."
  @spec block(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def block(user_id, blocked_id) do
    with {:ok, id} <- target(user_id, blocked_id),
         {:ok, _} <-
           Repo.transaction(fn ->
             lock_pair(user_id, id)

             case Repo.insert(Block.changeset(user_id, id),
                    on_conflict: :nothing,
                    conflict_target: [:user_id, :blocked_id]
                  ) do
               {:ok, _} -> :ok
               {:error, reason} -> Repo.rollback(reason)
             end

             Repo.delete_all(
               from f in Friendship,
                 where:
                   (f.user_id == ^user_id and f.friend_id == ^id) or
                     (f.user_id == ^id and f.friend_id == ^user_id)
             )

             Repo.delete_all(
               from i in Ignore,
                 where:
                   (i.user_id == ^user_id and i.ignored_id == ^id) or
                     (i.user_id == ^id and i.ignored_id == ^user_id)
             )
           end) do
      for affected_id <- [user_id, id] do
        Phoenix.PubSub.broadcast(
          PidroServer.PubSub,
          "lobby:updates",
          {:friends_changed, affected_id}
        )
      end

      changed(user_id, id)
      {:ok, list(user_id)}
    end
  end

  @doc "Removes only the caller's block; no friendship is restored."
  @spec unblock(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def unblock(user_id, blocked_id) do
    with {:ok, id} <- target(user_id, blocked_id) do
      Repo.delete_all(from b in Block, where: b.user_id == ^user_id and b.blocked_id == ^id)
      changed(user_id, id)
      {:ok, list(user_id)}
    end
  end

  @doc "Lists the caller's blocked players, newest first, without presence."
  @spec list(String.t()) :: map()
  def list(user_id) do
    ids =
      Repo.all(
        from b in Block,
          where: b.user_id == ^user_id,
          order_by: [desc: b.inserted_at, asc: b.blocked_id],
          select: b.blocked_id
      )

    users = PidroServer.Accounts.Auth.get_users_map(ids)

    blocked =
      for id <- ids, user = users[id], user do
        %{user_id: id, display_name: User.public_name(user), avatar_url: user.avatar_url}
      end

    %{blocked: blocked}
  end

  @doc "True when either player has blocked the other. Non-account occupants have no blocks."
  @spec blocked?(term(), term()) :: boolean()
  def blocked?(user_id, other_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         {:ok, other_id} <- Ecto.UUID.cast(other_id) do
      # Room admission must fail before its GenServer caller times out.
      Repo.exists?(from(b in subquery(blocked_ids(user_id)), where: b.id == ^other_id),
        timeout: 1_000
      )
    else
      :error -> false
    end
  end

  @doc "The ids of everyone blocked by or blocking `user_id`. Non-account occupants have none."
  @spec ids(term()) :: MapSet.t(String.t())
  def ids(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, user_id} ->
        MapSet.new(Repo.all(from(b in subquery(blocked_ids(user_id)), select: b.id)))

      :error ->
        MapSet.new()
    end
  end

  @doc "The topic a game channel follows so a block made at the table takes effect at once."
  @spec topic(String.t()) :: String.t()
  def topic(user_id), do: "blocks:#{user_id}"

  @doc "Excludes either-direction blocked pairs from a users query, in SQL."
  @spec excluding(Ecto.Queryable.t(), String.t()) :: Ecto.Query.t()
  def excluding(query, user_id) do
    from u in query, where: u.id not in subquery(blocked_ids(user_id))
  end

  @doc false
  # Friend adds, removes and blocks lock the same rows in order, so a racing add
  # cannot restore an edge after a block's delete, nor lose one to a remove.
  # Recheck existence under the locks because account deletion may have
  # committed since validation.
  @spec lock_pair(String.t(), String.t()) :: :ok
  def lock_pair(user_id, other_id) do
    users =
      Repo.all(
        from u in User,
          where: u.id in ^[user_id, other_id],
          order_by: u.id,
          lock: "FOR UPDATE"
      )

    case users do
      [%User{guest: false}, %User{guest: false}] -> :ok
      _ -> Repo.rollback(:user_not_found)
    end
  end

  defp changed(user_id, other_id) do
    for id <- [user_id, other_id],
        do: Phoenix.PubSub.broadcast(PidroServer.PubSub, topic(id), :blocks_changed)
  end

  defp blocked_ids(user_id) do
    incoming = from b in Block, where: b.blocked_id == ^user_id, select: %{id: b.user_id}

    from b in Block,
      where: b.user_id == ^user_id,
      select: %{id: b.blocked_id},
      union: ^incoming
  end

  defp target(user_id, blocked_id) do
    with :ok <- require_account(user_id),
         {:ok, id} <- Ecto.UUID.cast(blocked_id),
         false <- id == user_id,
         %User{guest: false} <- Repo.get(User, id) do
      {:ok, id}
    else
      {:error, :account_required} = error -> error
      true -> {:error, :cannot_block_self}
      _ -> {:error, :user_not_found}
    end
  end

  defp require_account(user_id) do
    case Repo.get(User, user_id) do
      %User{guest: false} -> :ok
      _ -> {:error, :account_required}
    end
  end
end

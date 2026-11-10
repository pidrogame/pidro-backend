defmodule PidroServer.Entitlements do
  @moduledoc """
  Who is Premium (PID-125). The server alone decides, from RevenueCat's
  record of the stores, mirrored into the `entitlements` table.

  This module is the only writer of `entitlements`: nothing else inserts,
  updates or deletes a row, and no date is ever set by hand. Every write
  starts from what RevenueCat answers for the player (`sync_from_revenuecat/2`);
  a promotional grant goes through RevenueCat first and is then synced back.
  Admin's reads (`summary/0`, `list/1`) only read.
  """

  import Ecto.Query, only: [from: 2]

  alias PidroServer.Accounts.User
  alias PidroServer.Entitlements.{Entitlement, RevenueCatEvent}
  alias PidroServer.Repo
  alias PidroServer.RevenueCat

  @premium "premium"
  @granted_sources ~w(promotional classic_honored)

  @doc """
  Whether a player is Premium: an active `premium` row that never ends or ends
  in the future. One query. Without RevenueCat configured nobody is Premium.
  """
  @spec premium?(%{id: Ecto.UUID.t()} | Ecto.UUID.t()) :: boolean()
  def premium?(%{id: user_id}), do: premium?(user_id)

  def premium?(user_id) when is_binary(user_id),
    do: RevenueCat.configured?() and Repo.exists?(active_premium(user_id))

  @doc """
  The `premium` rows active right now, as a query for reads that build on it:
  `active`, and an `expires_at` that is nil (lifetime) or in the future. It
  does not ask whether RevenueCat is configured.
  """
  @spec premium_now() :: Ecto.Query.t()
  def premium_now do
    now = DateTime.utc_now()

    from e in Entitlement,
      where:
        e.entitlement == @premium and e.active and
          (is_nil(e.expires_at) or e.expires_at > ^now)
  end

  @doc """
  How many players are Premium right now, by `store` and by `source`, and how
  many of them end within 7 days. One query.
  """
  @spec summary() :: %{
          total: non_neg_integer(),
          by_store: %{optional(String.t() | nil) => pos_integer()},
          by_source: %{optional(String.t()) => pos_integer()},
          expiring_soon: non_neg_integer()
        }
  def summary do
    week = DateTime.add(DateTime.utc_now(), 7, :day)

    from(e in premium_now(),
      group_by: [e.store, e.source],
      select: {e.store, e.source, count(e.id), filter(count(e.id), e.expires_at <= ^week)}
    )
    |> Repo.all()
    |> Enum.reduce(
      %{total: 0, by_store: %{}, by_source: %{}, expiring_soon: 0},
      fn {store, source, count, soon}, acc ->
        %{
          total: acc.total + count,
          by_store: Map.update(acc.by_store, store, count, &(&1 + count)),
          by_source: Map.update(acc.by_source, source, count, &(&1 + count)),
          expiring_soon: acc.expiring_soon + soon
        }
      end
    )
  end

  @doc """
  Every `premium` row with its player's public name, soonest `expires_at`
  first and lifetime last. `active` is whether it counts right now.
  `active_only: true` keeps only those. One query.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    now = DateTime.utc_now()
    rows = if opts[:active_only], do: premium_now(), else: Entitlement

    Repo.all(
      from e in rows,
        join: u in User,
        on: u.id == e.user_id,
        where: e.entitlement == @premium,
        order_by: [asc_nulls_last: e.expires_at, asc: u.username],
        select: %{
          user_id: u.id,
          name: coalesce(u.display_name, u.username),
          active: e.active and (is_nil(e.expires_at) or e.expires_at > ^now),
          expires_at: e.expires_at,
          store: e.store,
          source: e.source,
          product_id: e.product_id,
          last_synced_at: e.last_synced_at
        }
    )
  end

  @doc "The player's `premium` row, or nil."
  @spec get(Ecto.UUID.t()) :: Entitlement.t() | nil
  def get(user_id), do: Repo.get_by(Entitlement, user_id: user_id, entitlement: @premium)

  @doc "The Premium fields for the player's JSON."
  @spec premium_fields(%{id: Ecto.UUID.t()}) :: %{
          premium: boolean(),
          premium_until: DateTime.t() | nil,
          premium_source: String.t() | nil
        }
  def premium_fields(%{id: user_id}) do
    case RevenueCat.configured?() and Repo.one(active_premium(user_id)) do
      %Entitlement{} = row ->
        %{premium: true, premium_until: row.expires_at, premium_source: row.source}

      _none ->
        %{premium: false, premium_until: nil, premium_source: nil}
    end
  end

  @doc """
  Asks RevenueCat for the player and writes what it says about `premium`.

  An entitlement with no `expires_date` is lifetime; one in the future is
  active, one in the past inactive. When RevenueCat lists no `premium` at all,
  an existing row turns inactive and no row is created. Ids that are not one
  of our players are never sent to RevenueCat, which would create them.
  """
  @spec sync_from_revenuecat(String.t(), String.t() | nil) ::
          {:ok, Entitlement.t() | nil} | {:error, term()}
  def sync_from_revenuecat(user_id, event_id \\ nil), do: sync(user_id, event_id, nil)

  @doc """
  Grants Premium until `ends_at` through RevenueCat, syncs it back and records
  why it was granted (`promotional` or `classic_honored`).
  """
  @spec grant_promotional(Ecto.UUID.t(), DateTime.t(), String.t()) ::
          {:ok, Entitlement.t()} | {:error, term()}
  def grant_promotional(user_id, %DateTime{} = ends_at, source) when source in @granted_sources do
    with {:ok, uuid} <- check_user(user_id),
         :ok <-
           RevenueCat.grant_promotional(uuid, @premium, DateTime.to_unix(ends_at, :millisecond)),
         {:ok, %Entitlement{} = row} <- sync(uuid, nil, source) do
      {:ok, row}
    else
      {:ok, nil} -> {:error, :not_granted}
      error -> error
    end
  end

  @doc """
  Takes one RevenueCat webhook event: stores it once by its id, then syncs
  every player it names (`app_user_id`, and for `TRANSFER` everyone in
  `transferred_from` and `transferred_to`). An event already processed is
  `:duplicate` and syncs nothing. Ids that are not our players (Classic's
  integer ids) are skipped and recorded as `"not a user id"`. Unknown types
  are handled like any other. A failed sync leaves the event unprocessed with
  its error, so RevenueCat's retry runs it again.
  """
  @spec receive_event(map()) :: :ok | :duplicate | {:error, term()}
  def receive_event(%{"id" => id, "type" => type} = event)
      when is_binary(id) and is_binary(type) do
    {:ok, stored} =
      Repo.insert(
        %RevenueCatEvent{
          event_id: id,
          type: type,
          app_user_id: id_string(event["app_user_id"]),
          payload: event
        },
        on_conflict: {:replace, [:updated_at]},
        conflict_target: :event_id,
        returning: true
      )

    if stored.processed_at, do: :duplicate, else: process(stored, event)
  end

  def receive_event(_event), do: {:error, :bad_event}

  @spec last_event(Ecto.UUID.t()) :: RevenueCatEvent.t() | nil
  def last_event(user_id) do
    Repo.one(
      from e in RevenueCatEvent,
        where: e.app_user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  defp process(stored, event) do
    ids =
      if(event["type"] == "TRANSFER",
        do: [
          event["app_user_id"]
          | List.wrap(event["transferred_from"]) ++ List.wrap(event["transferred_to"])
        ],
        else: [event["app_user_id"]]
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&id_string/1)
      |> Enum.uniq()

    result =
      Enum.reduce_while(ids, :ok, fn id, acc ->
        case sync_from_revenuecat(id, stored.event_id) do
          {:ok, _row} -> {:cont, acc}
          {:error, :not_a_user} -> {:cont, :skipped}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, reason} ->
        stored |> Ecto.Changeset.change(error: inspect(reason)) |> Repo.update!()
        {:error, reason}

      outcome ->
        error = if outcome == :skipped, do: "not a user id"
        stored |> Ecto.Changeset.change(error: error, processed_at: now()) |> Repo.update!()
        :ok
    end
  end

  defp id_string(id) when is_binary(id), do: id
  defp id_string(id) when is_integer(id), do: Integer.to_string(id)
  defp id_string(_id), do: nil

  defp active_premium(user_id), do: from(e in premium_now(), where: e.user_id == ^user_id)

  # `granted` is the reason a grant was made, recorded when RevenueCat reports
  # the entitlement as promotional.
  defp sync(user_id, event_id, granted) do
    with {:ok, uuid} <- check_user(user_id),
         {:ok, subscriber} <- RevenueCat.get_subscriber(uuid) do
      write(get(uuid), uuid, subscriber, event_id, granted)
    end
  end

  # Only the canonical lower-case form of one of our ids reaches RevenueCat,
  # whose ids are case-sensitive.
  defp check_user(user_id) when byte_size(user_id) == 36 do
    with {:ok, uuid} <- Ecto.UUID.cast(user_id),
         true <- Repo.exists?(from u in User, where: u.id == ^uuid) do
      {:ok, uuid}
    else
      _ -> {:error, :not_a_user}
    end
  end

  defp check_user(_user_id), do: {:error, :not_a_user}

  defp write(nil, _user_id, %{"entitlements" => entitlements} = _subscriber, _event_id, _granted)
       when not is_map_key(entitlements, @premium),
       do: {:ok, nil}

  defp write(
         %Entitlement{} = row,
         _user_id,
         %{"entitlements" => entitlements},
         event_id,
         _granted
       )
       when not is_map_key(entitlements, @premium) do
    row
    |> Ecto.Changeset.change(active: false, last_synced_at: now())
    |> put_event(event_id)
    |> Repo.update()
  end

  defp write(
         row,
         user_id,
         %{"entitlements" => %{@premium => premium}} = subscriber,
         event_id,
         granted
       ) do
    product = premium["product_identifier"]
    store = store(subscriber, product)

    with {:ok, expires_at} <- expires_at(premium["expires_date"]) do
      attrs = %{
        user_id: user_id,
        entitlement: @premium,
        active: expires_at == nil or DateTime.after?(expires_at, DateTime.utc_now()),
        expires_at: expires_at,
        product_id: product,
        store: store,
        source: source(row, store, granted),
        rc_original_app_user_id: subscriber["original_app_user_id"],
        last_synced_at: now()
      }

      attrs = if event_id, do: Map.put(attrs, :last_event_id, event_id), else: attrs

      Repo.insert(struct(Entitlement, attrs),
        on_conflict: {:replace, [:updated_at | Map.keys(attrs) -- [:user_id, :entitlement]]},
        conflict_target: [:user_id, :entitlement],
        returning: true
      )
    end
  end

  defp write(_row, _user_id, _subscriber, _event_id, _granted), do: {:error, :bad_answer}

  # A subscription names its store in `subscriptions`; a one-off purchase
  # (lifetime) in its latest `non_subscriptions` entry.
  defp store(subscriber, product) do
    case get_in(subscriber, ["subscriptions", product, "store"]) do
      nil -> subscriber |> get_in(["non_subscriptions", product]) |> List.wrap() |> latest_store()
      store -> store
    end
  end

  defp latest_store([]), do: nil
  defp latest_store(purchases), do: List.last(purchases)["store"]

  # A store purchase is `store`. A RevenueCat grant is the reason it was granted
  # for: the one this sync was made for, else the one already recorded.
  defp source(_row, "promotional", granted) when granted in @granted_sources, do: granted

  defp source(%Entitlement{source: source}, "promotional", _granted)
       when source in @granted_sources,
       do: source

  defp source(_row, "promotional", _granted), do: "promotional"
  defp source(_row, _store, _granted), do: "store"

  defp expires_at(nil), do: {:ok, nil}

  defp expires_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> {:error, :bad_answer}
    end
  end

  defp expires_at(_other), do: {:error, :bad_answer}

  defp put_event(changeset, nil), do: changeset

  defp put_event(changeset, event_id),
    do: Ecto.Changeset.put_change(changeset, :last_event_id, event_id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

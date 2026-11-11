defmodule PidroServer.ClassicPremium do
  @moduledoc """
  Carries a claimed player's running Classic Premium over (PID-391), so a
  Classic subscriber never pays twice.

  Each attempt reads Classic's `premium_until` by the linked Classic id and,
  while it runs, grants Premium until that date through
  `PidroServer.Entitlements` (`classic_honored`). The outcome is one
  `classic_premium_carryovers` row per player: `pending` until Classic and
  RevenueCat both answered, then `granted`, `imported` (already Premium from
  a store), `ended` or `none`. Nothing here writes `entitlements` itself.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PidroServer.Accounts.{ClassicClient, User}
  alias PidroServer.ClassicPremium.Carryover
  alias PidroServer.Entitlements
  alias PidroServer.Entitlements.Entitlement
  alias PidroServer.Profiles
  alias PidroServer.Repo
  alias PidroServer.RevenueCat

  # The longest grant. RevenueCat once said a promotional grant lasts at most
  # a year: try 13 months once against its sandbox before launch.
  @max_grant_months 13
  # A grant the cap cut short is extended once it ends within this many days.
  @extend_within_days 30
  # A claim tells the player their Classic Premium ended only this recently.
  @ended_told_months 12

  @doc """
  Carries the player's Classic Premium over, or records why not yet
  (`attempts` counts the failures since the last success). Safe to
  repeat: a `granted` player's grant is extended only when Classic's date
  moved forward or the cap cut it short and it is running out. Never raises.
  Without RevenueCat configured it writes nothing and answers `{:ok, nil}`.
  """
  @spec carry_over(%{id: Ecto.UUID.t(), classic_user_id: integer() | nil}) ::
          {:ok, Carryover.t() | nil}
  def carry_over(%{id: user_id, classic_user_id: classic_user_id})
      when is_integer(classic_user_id) do
    if RevenueCat.configured?(),
      do: {:ok, user_id |> start(classic_user_id) |> attempt()},
      else: {:ok, nil}
  rescue
    exception ->
      Logger.error(
        "Classic Premium carry-over for user #{user_id} failed: #{Exception.message(exception)}"
      )

      {:ok, nil}
  end

  def carry_over(_user), do: {:ok, nil}

  @doc "The player's carry-over row, or nil."
  @spec get(Ecto.UUID.t()) :: Carryover.t() | nil
  def get(user_id), do: Repo.get_by(Carryover, user_id: user_id)

  @doc """
  What a claim's answer says about Classic Premium, or nil to say nothing.
  `pending` is said only to a player whose Classic Premium was running when
  they claimed, `ended` only within #{@ended_told_months} months of its date.
  """
  @spec answer(Carryover.t() | nil) :: %{state: String.t(), until: DateTime.t() | nil} | nil
  def answer(%Carryover{state: state, classic_premium_until: until})
      when state in ~w(granted imported),
      do: %{state: "carried", until: until}

  def answer(%Carryover{state: "ended", classic_premium_until: until}) do
    if DateTime.after?(until, DateTime.shift(DateTime.utc_now(), month: -@ended_told_months)),
      do: %{state: "ended", until: until}
  end

  def answer(%Carryover{state: "pending", user_id: user_id}) do
    if Repo.exists?(
         from p in Profiles.classic_subscriber_profiles(), where: p.user_id == ^user_id
       ),
       do: %{state: "pending", until: nil}
  end

  def answer(_nothing), do: nil

  @doc """
  Queues every claimed Classic subscriber (`legacy_premium`) who has no
  carry-over row yet as `pending`, for the retry job. Answers how many.
  """
  @spec queue_claimed() :: non_neg_integer()
  def queue_claimed do
    now = now()

    from(p in Profiles.classic_subscriber_profiles(),
      join: u in User,
      on: u.id == p.user_id,
      left_join: c in Carryover,
      on: c.user_id == u.id,
      where: is_nil(c.id) and not is_nil(u.classic_user_id),
      select: %{user_id: u.id, classic_user_id: u.classic_user_id}
    )
    |> Repo.all()
    |> Enum.map(
      &Map.merge(&1, %{
        id: Ecto.UUID.generate(),
        state: "pending",
        inserted_at: now,
        updated_at: now
      })
    )
    |> Enum.chunk_every(1_000)
    |> Enum.reduce(0, fn rows, count ->
      {inserted, _} =
        Repo.insert_all(Carryover, rows, on_conflict: :nothing, conflict_target: :user_id)

      count + inserted
    end)
  end

  defp start(user_id, classic_user_id) do
    Repo.insert!(
      %Carryover{user_id: user_id, classic_user_id: classic_user_id, state: "pending"},
      on_conflict: {:replace, [:classic_user_id]},
      conflict_target: :user_id,
      returning: true
    )
  end

  defp attempt(row) do
    case carry(row, Entitlements.get(row.user_id)) do
      {:ok, row} -> row
      {:error, reason} -> fail(row, inspect(reason))
    end
  rescue
    exception -> fail(row, Exception.message(exception))
  catch
    kind, reason -> fail(row, inspect({kind, reason}))
  end

  defp carry(row, %Entitlement{source: "store"} = premium) do
    if running_until(premium),
      do: save(row, state: "imported"),
      else: carry(row, nil)
  end

  defp carry(row, premium) do
    with {:ok, classic} <- classic(row.classic_user_id),
         {:ok, until} <- premium_until(classic["premium_until"]) do
      honor(row, classic, until, premium)
    end
  end

  # Classic verified this id at claim, so even "not found" is a failure.
  defp classic(classic_user_id) do
    with {:error, reason} <- ClassicClient.lookup(:id, classic_user_id),
         do: {:error, {:classic, reason}}
  end

  defp honor(row, _classic, nil, _premium), do: save(row, state: "none")

  defp honor(row, classic, until, premium) do
    cond do
      not DateTime.after?(until, DateTime.utc_now()) ->
        save(row, state: "ended", classic_premium_until: until)

      grant?(row, until, premium) ->
        grant(row, classic, until)

      true ->
        save(row, state: "granted", classic_premium_until: until)
    end
  end

  # Grant when nothing runs now; else only to reach Classic's date, when it
  # moved forward (HQ moves it on every renewal) or the running grant ends soon.
  defp grant?(row, until, premium) do
    case running_until(premium) do
      nil ->
        true

      :never ->
        false

      ends_at ->
        DateTime.before?(ends_at, until) and
          (moved_forward?(row, until) or
             DateTime.before?(
               ends_at,
               DateTime.add(DateTime.utc_now(), @extend_within_days, :day)
             ))
    end
  end

  defp moved_forward?(%Carryover{classic_premium_until: nil}, _until), do: true

  defp moved_forward?(%Carryover{classic_premium_until: seen}, until),
    do: DateTime.after?(until, seen)

  # PID-391 part 2 adds a clause above this one for a profile with a
  # `premium_store`: it imports that subscription into RevenueCat first.
  defp grant(row, _classic, until) do
    cap =
      DateTime.utc_now() |> DateTime.shift(month: @max_grant_months) |> DateTime.truncate(:second)

    ends_at = Enum.min([until, cap], DateTime)

    with {:ok, _premium} <-
           Entitlements.grant_promotional(row.user_id, ends_at, "classic_honored") do
      save(row, state: "granted", classic_premium_until: until)
    end
  end

  defp running_until(%Entitlement{active: true, expires_at: nil}), do: :never

  defp running_until(%Entitlement{active: true, expires_at: ends_at}) do
    if DateTime.after?(ends_at, DateTime.utc_now()), do: ends_at
  end

  defp running_until(_premium), do: nil

  defp premium_until(nil), do: {:ok, nil}

  defp premium_until(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, until, _offset} ->
        {:ok, DateTime.truncate(until, :second)}

      # Classic sends `member_since` without an offset; such a date is UTC.
      {:error, :missing_offset} ->
        {:ok,
         value
         |> NaiveDateTime.from_iso8601!()
         |> DateTime.from_naive!("Etc/UTC")
         |> DateTime.truncate(:second)}

      {:error, _reason} ->
        {:error, {:classic, :bad_premium_until}}
    end
  end

  defp premium_until(_value), do: {:error, {:classic, :bad_premium_until}}

  defp save(row, changes) do
    row
    |> Ecto.Changeset.change([attempts: 0, last_error: nil, last_tried_at: now()] ++ changes)
    |> Repo.update()
  end

  # A granted player stays granted while Classic or RevenueCat is down: the
  # retry job keeps visiting them. Everything else waits as `pending`.
  defp fail(row, reason) do
    Logger.error("Classic Premium carry-over for user #{row.user_id} failed: #{reason}")

    row
    |> Ecto.Changeset.change(
      state: if(row.state == "granted", do: "granted", else: "pending"),
      attempts: row.attempts + 1,
      last_error: String.slice(reason, 0, 255),
      last_tried_at: now()
    )
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

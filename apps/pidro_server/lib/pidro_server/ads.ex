defmodule PidroServer.Ads do
  @moduledoc """
  Who watches a short ad before a solo game, and when (PID-123).

  The schedule is `PidroServer.Ads.Schedule` over the admin values in
  `PidroServer.Settings`. Only free adults are eligible, and only while
  `ads_enabled` is on. The app reads the decision from `/me`; an ad-aware
  client that creates a solo room is held to it (`admit_solo_room/1`), an
  older client never is.

  A watched ad, or one that could not be shown, gives one credit, valid ten
  minutes, that lets an ad-aware client create a solo room; the start of a
  solo game uses it up (`Profiles.count_solo_start/1`), so a failed create or
  a lost response never costs a second ad. The server
  never sees the ad itself, so a tampered client can claim a credit without
  watching: that costs one ad and nothing else.
  """

  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.Ads.{Event, Schedule}
  alias PidroServer.{Entitlements, Profiles, Repo, Settings}
  alias PidroServer.Profiles.PlayerProfile

  @type decision :: %{
          eligible: boolean(),
          next_game_needs_ad: boolean(),
          games_until_ad: non_neg_integer(),
          free_games_left: non_neg_integer()
        }

  @ineligible %{eligible: false, next_game_needs_ad: false, games_until_ad: 0, free_games_left: 0}
  @credit_seconds 10 * 60
  @kinds [:offered, :watched, :unavailable, :dismissed]

  @doc """
  Whether `user` is eligible for ads and what that means for their next solo
  game. Eligible is `ads_enabled`, an adult (`age_band == "18_plus"`) and not
  premium; for anyone else every other field is false or 0.
  """
  @spec decision(User.t()) :: decision()
  def decision(%User{} = user), do: user |> decide() |> elem(0)

  @doc """
  The decision for `/me`. When an ad-aware client is told the next solo game
  needs an ad, the offer is counted, once for that game however often `/me` is
  read; an older client, which cannot show one, is not counted.
  """
  @spec offer(User.t(), boolean()) :: decision()
  def offer(%User{} = user, ads_aware?) do
    {decision, solo} = decide(user)
    if ads_aware?, do: record_offer(decision, user, solo)
    decision
  end

  @doc """
  Lets an ad-aware client create a solo room: always, unless the next solo
  game needs an ad and the user holds no credit.
  """
  @spec admit_solo_room(User.t()) :: :ok | {:error, {:ad_required, decision()}}
  def admit_solo_room(%User{} = user) do
    case {decide(user), credit?(user)} do
      {{%{next_game_needs_ad: true} = decision, solo}, false} ->
        record_offer(decision, user, solo)
        {:error, {:ad_required, decision}}

      _admitted ->
        :ok
    end
  end

  @doc """
  Records what the app reports. `:watched` and `:unavailable` (no fill, an
  error, no SDK) both give the one credit and differ only in the event.
  """
  @spec report(User.t(), :watched | :unavailable | :dismissed) :: :ok
  def report(%User{} = user, :dismissed), do: record(user, :dismissed)

  def report(%User{} = user, kind) when kind in [:watched, :unavailable] do
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    expires_at = DateTime.add(DateTime.utc_now(), @credit_seconds)

    Repo.update_all(from(p in PlayerProfile, where: p.id == ^profile.id),
      set: [ad_credit_expires_at: expires_at]
    )

    record(user, kind)
  end

  @doc "Each kind's count per UTC day for the last `days` days, newest first."
  @spec daily_counts(pos_integer()) :: [map()]
  def daily_counts(days) do
    today = Date.utc_today()
    first = Date.add(today, 1 - days)

    counts =
      Repo.all(
        from e in Event,
          where: e.inserted_at >= ^DateTime.new!(first, ~T[00:00:00]),
          group_by: [fragment("(?)::date", e.inserted_at), e.kind],
          select: {{fragment("(?)::date", e.inserted_at), e.kind}, count()}
      )
      |> Map.new()

    for date <- Date.range(today, first, -1) do
      Map.new(@kinds, &{&1, Map.get(counts, {date, Atom.to_string(&1)}, 0)})
      |> Map.put(:date, date)
    end
  end

  @doc "Adults, not premium, whose record has reached the free games: who the schedule applies to."
  @spec adults_past_free_games(Settings.ads()) :: non_neg_integer()
  def adults_past_free_games(%{ads_free_games: free}) do
    from(u in User,
      left_join: p in PlayerProfile,
      on: p.user_id == u.id,
      where: u.age_band == "18_plus",
      select: {u.id, p}
    )
    |> Repo.all()
    |> Enum.count(fn {user_id, profile} ->
      Profiles.record(profile || %PlayerProfile{}).games >= free and
        not Entitlements.premium?(user_id)
    end)
  end

  defp decide(user) do
    settings = Settings.ads()

    if settings.ads_enabled and user.age_band == "18_plus" and not Entitlements.premium?(user.id) do
      profile = Repo.get_by(PlayerProfile, user_id: user.id) || %PlayerProfile{}
      games = Profiles.record(profile).games
      solo = profile.solo_games_started

      {%{
         eligible: true,
         next_game_needs_ad: Schedule.needs_ad?(settings, games, solo),
         games_until_ad: Schedule.games_until_ad(settings, games, solo),
         free_games_left: max(settings.ads_free_games - games, 0)
       }, solo}
    else
      {@ineligible, nil}
    end
  end

  defp credit?(user) do
    now = DateTime.utc_now()

    Repo.exists?(
      from p in PlayerProfile, where: p.user_id == ^user.id and p.ad_credit_expires_at > ^now
    )
  end

  # The partial unique index keeps one offer per user and solo count.
  defp record_offer(%{next_game_needs_ad: true}, user, solo) do
    Repo.insert_all(
      Event,
      [
        %{
          user_id: user.id,
          kind: "offered",
          solo_games_started: solo,
          inserted_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing
    )

    :ok
  end

  defp record_offer(_decision, _user, _solo), do: :ok

  defp record(user, kind) do
    Repo.insert_all(Event, [
      %{user_id: user.id, kind: Atom.to_string(kind), inserted_at: DateTime.utc_now()}
    ])

    :ok
  end
end

defmodule PidroServer.Profiles do
  @moduledoc """
  Context for per-user profiles and lifetime stats rollups.

  A `PidroServer.Profiles.PlayerProfile` is one durable row per user, created
  lazily. It holds lifetime play counters (`games_played`, `wins`, `losses`)
  maintained incrementally on game completion (via the `Stats.save_completed_game/4`
  hook) and rebuildable from `game_stats` history. Derived values such as
  `win_rate`, `avg_winning_bid`, and `account_age_days` are computed at read time,
  never stored.

  Progression columns (rating, veteran/XP, playstyle, heritage) ship with
  defaults and are owned by later tickets (PID-45..PID-51); PID-44 does not write
  them.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PidroServer.Accounts.User
  alias PidroServer.Achievements
  alias PidroServer.Achievements.Catalog
  alias PidroServer.Playstyle
  alias PidroServer.Profiles.Achievement
  alias PidroServer.Profiles.GameXp
  alias PidroServer.Profiles.LegacyProgression
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Profiles.PostGameSummary
  alias PidroServer.Profiles.RatingState
  alias PidroServer.Progression
  alias PidroServer.Progression.Heritage
  alias PidroServer.Rating
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

  @typedoc "A player rating `{mu, sigma}`, as `PidroServer.Rating`."
  @type rating :: {float(), float()}

  @doc """
  Returns the profile for a user, creating a default row lazily if absent.

  Race-safe: a concurrent insert against the unique `user_id` index is absorbed
  by `on_conflict: :nothing` followed by a re-fetch.
  """
  @spec get_or_create_profile(Ecto.UUID.t()) ::
          {:ok, PlayerProfile.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_profile(user_id) do
    case Repo.get_by(PlayerProfile, user_id: user_id) do
      %PlayerProfile{} = profile ->
        {:ok, profile}

      nil ->
        %PlayerProfile{}
        |> PlayerProfile.changeset(%{user_id: user_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :user_id)
        |> case do
          {:ok, %PlayerProfile{}} ->
            # UUIDs are generated before insert, so the struct cannot tell us
            # whether ON CONFLICT inserted. The row is the source of truth.
            {:ok, Repo.get_by!(PlayerProfile, user_id: user_id)}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Imports a Pidro 1 player's progression into their Pidro 2 profile (PID-53).

  The pure legacy → profile mapping: adds Classic XP to Veteran XP, retains the
  raw Classic career in Heritage flags, and adds the bridge's pre-aggregated
  playstyle facts. New-game results, rating, and achievements are untouched.

  `legacy_data` is a `%LegacyProgression{}` or a plain map (normalized via
  `struct/2`, so any missing/`nil` field falls to its struct default). The first
  argument is a `user_id` or a `%User{}` (resolved to its id) for the future
  bridge call site.

  The import is one `PlayerProfile.changeset/2` write wrapped in a transaction.

  ## Idempotency

  Guards on `heritage_flags["played_pidro_one"] == true` — the marker the import
  itself sets. A re-run short-circuits with `{:ok, :already_migrated}` and writes
  nothing, so it can never clobber XP/skill/playstyle the player earned *after*
  migrating. There is deliberately no `force:` escape hatch in v1; a re-apply
  would be a separate operational tool.

  Returns `{:ok, profile}` on a fresh import, `{:ok, :already_migrated}` when the
  guard short-circuits, or `{:error, changeset}` on a write failure.
  """
  @spec import_legacy_progression(Ecto.UUID.t() | User.t(), LegacyProgression.t() | map()) ::
          {:ok, PlayerProfile.t()} | {:ok, :already_migrated} | {:error, Ecto.Changeset.t()}
  def import_legacy_progression(user_or_id, legacy_data) do
    user_id = user_id_from(user_or_id)
    legacy = normalize_legacy(legacy_data)

    Repo.transaction(fn ->
      {:ok, profile} = get_or_create_profile(user_id)

      profile =
        Repo.one!(from p in PlayerProfile, where: p.id == ^profile.id, lock: "FOR UPDATE")

      if already_migrated?(profile) do
        :already_migrated
      else
        case profile |> PlayerProfile.changeset(legacy_attrs(profile, legacy)) |> Repo.update() do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  defp user_id_from(%User{id: id}), do: id
  defp user_id_from(user_id) when is_binary(user_id), do: user_id

  defp normalize_legacy(%LegacyProgression{} = legacy), do: legacy
  defp normalize_legacy(map) when is_map(map), do: LegacyProgression.new(map)

  defp already_migrated?(%PlayerProfile{heritage_flags: flags}) when is_map(flags) do
    Map.get(flags, "played_pidro_one") == true or Map.get(flags, :played_pidro_one) == true
  end

  defp already_migrated?(_profile), do: false

  defp legacy_attrs(%PlayerProfile{} = profile, %LegacyProgression{} = legacy) do
    veteran_xp = profile.veteran_xp + legacy.xp

    %{attempts: attempts, wins: wins, won_bid_sum: won_bid_sum} =
      legacy_playstyle(legacy.playstyle)

    %{
      veteran_xp: veteran_xp,
      veteran_level: Progression.level_for_xp(veteran_xp),
      heritage_flags: Map.merge(profile.heritage_flags || %{}, legacy_heritage(legacy)),
      playstyle_bidding_attempts: profile.playstyle_bidding_attempts + attempts,
      playstyle_bidding_wins: profile.playstyle_bidding_wins + wins,
      avg_winning_bid_sum: profile.avg_winning_bid_sum + won_bid_sum,
      avg_winning_bid_count: profile.avg_winning_bid_count + wins
    }
  end

  defp legacy_heritage(%LegacyProgression{} = legacy) do
    %{
      "played_pidro_one" => true,
      "classic_user_id" => legacy.classic_user_id,
      "classic_username" => legacy.classic_username,
      "classic_name_allowed" => legacy.classic_name_allowed,
      "classic_level" => legacy.classic_level,
      "legacy_played_games" => legacy.legacy_played_games,
      "legacy_victories" => legacy.legacy_victories,
      "legacy_losses" => legacy.legacy_losses,
      "games_played_counter" => legacy.games_played_counter,
      "wins" => legacy.wins,
      "losses" => legacy.losses,
      "games_logged" => legacy.games_logged,
      "games_started" => legacy.games_started,
      "games_ended" => legacy.games_ended,
      "member_since" => legacy.member_since,
      "premium" => legacy.premium,
      "badges" => legacy.badges,
      # Existing Heritage badges remain compatible with imported profiles.
      "legacy_level" => legacy.classic_level,
      "legacy_accolades" => legacy.badges || [],
      "founding_member" => legacy.founding_member,
      "legacy_premium" => legacy.premium == true
    }
  end

  defp legacy_playstyle(nil), do: %{attempts: 0, wins: 0, won_bid_sum: 0}

  defp legacy_playstyle(%{} = ps) do
    %{
      attempts: legacy_int(ps, :bidding_attempts, "bidding_attempts"),
      wins: legacy_int(ps, :bidding_wins, "bidding_wins"),
      won_bid_sum: legacy_int(ps, :won_bid_sum, "won_bid_sum")
    }
  end

  defp legacy_int(map, atom_key, string_key) do
    value = Map.get(map, atom_key) || Map.get(map, string_key)
    if is_integer(value), do: value, else: 0
  end

  @doc """
  Single cheap fetch for the profile screen.

  Returns the stored profile fields plus derived values (`win_rate`,
  `avg_winning_bid`, `first_seen_at`, `account_age_days`). Lazily creates the
  profile row. This is a unique-index lookup — no `game_stats` array scan.
  """
  @spec get_profile_for_screen(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def get_profile_for_screen(user_id) do
    with {:ok, profile} <- get_or_create_profile(user_id) do
      first_seen_at = first_seen_at(user_id)
      earned = list_achievements(user_id)
      earned_keys = MapSet.new(earned, & &1.achievement_key)

      # Playstyle (PID-51): derive the needle/label/avg-bid from the accumulators.
      rate =
        Playstyle.bidding_win_rate(
          profile.playstyle_bidding_wins,
          profile.playstyle_bidding_attempts
        )

      needle = Playstyle.needle(rate)

      {:ok,
       %{
         user_id: profile.user_id,
         games_played: profile.games_played,
         wins: profile.wins,
         losses: profile.losses,
         win_rate: win_rate(profile.wins, profile.games_played),
         rating_mu: profile.rating_mu,
         rating_sigma: profile.rating_sigma,
         rating_games_count: profile.rating_games_count,
         # veteran_level recomputed from XP (canonical) so a stale cache can never
         # surface; equals the stored cache by construction once any game/rebuild ran.
         veteran_level: Progression.level_for_xp(profile.veteran_xp),
         veteran_xp: profile.veteran_xp,
         veteran_title: Progression.title_for_level(Progression.level_for_xp(profile.veteran_xp)),
         veteran_progress: Progression.level_progress(profile.veteran_xp),
         # Prestige (uncapped tail past the L100 cap) — recomputed from canonical
         # XP on read, never stored. `veteran_prestige_progress` is nil below the
         # cap (no ring) and `{into, step}` at/over it.
         veteran_prestige: Progression.prestige_for_xp(profile.veteran_xp),
         veteran_prestige_progress: Progression.prestige_progress(profile.veteran_xp),
         playstyle_bidding_wins: profile.playstyle_bidding_wins,
         playstyle_bidding_attempts: profile.playstyle_bidding_attempts,
         # PID-51 derived playstyle view (raw counters kept above — internal):
         bidding_win_rate: if(rate == :insufficient, do: nil, else: rate),
         aggression_needle: needle,
         aggression_label: Playstyle.label(needle),
         aggression_insufficient: rate == :insufficient,
         avg_winning_bid:
           Playstyle.avg_winning_bid(profile.avg_winning_bid_sum, profile.avg_winning_bid_count),
         heritage_flags: profile.heritage_flags,
         heritage: Heritage.display(profile.heritage_flags),
         first_seen_at: first_seen_at,
         account_age_days: account_age_days(first_seen_at),
         # PID-50: earned achievements (joined to Catalog for display copy) +
         # an optional active-catalog view with an `earned` flag so a UI can
         # show locked achievements. Dormant defs are NOT surfaced.
         achievements: screen_achievements(earned),
         achievements_catalog: screen_catalog(earned_keys)
       }}
    end
  end

  @doc """
  Bulk progression summaries for a list of user ids, in ONE query.

  Returns `%{user_id => %{veteran_level: pos_integer(), prestige:
  non_neg_integer(), tier: Rating.Tier.tier(), provisional: boolean(), pin:
  "classic" | nil}}`. Each value carries the canonical level and Legend stars
  (both recomputed from stored XP, so a stale `veteran_level` cache can never
  surface), the skill tier classified in memory via
  `Rating.Tier.classify/1`, and the pin shown on a seat (`"classic"` for a
  claimed Classic account). Users without a `player_profiles` row are simply
  absent from the map; the caller renders sane defaults (level 1 / provisional)
  for them.

  This is the no-N+1 companion to the per-row list view: one indexed `IN` scan
  over `player_profiles`, tier classification done in Elixir.
  """
  @spec summaries_for([Ecto.UUID.t()]) ::
          %{
            optional(Ecto.UUID.t()) => %{
              veteran_level: pos_integer(),
              prestige: non_neg_integer(),
              tier: atom(),
              provisional: boolean(),
              pin: String.t() | nil
            }
          }
  def summaries_for([]), do: %{}

  def summaries_for(user_ids) when is_list(user_ids) do
    from(p in PlayerProfile,
      where: p.user_id in ^user_ids,
      select:
        {p.user_id, p.veteran_xp, p.rating_mu, p.rating_sigma, p.rating_games_count,
         p.heritage_flags}
    )
    |> Repo.all()
    |> Map.new(fn {user_id, veteran_xp, mu, sigma, games_count, heritage_flags} ->
      %{tier: tier, provisional: provisional} = Rating.Tier.classify(mu, sigma, games_count)

      {user_id,
       %{
         veteran_level: Progression.level_for_xp(veteran_xp),
         prestige: Progression.prestige_for_xp(veteran_xp),
         tier: tier,
         provisional: provisional,
         pin: pin(heritage_flags)
       }}
    end)
  end

  defp pin(heritage_flags),
    do: if(heritage_value(heritage_flags, :played_pidro_one) == true, do: "classic")

  @doc """
  What another player's sheet shows about `user_id` to `viewer_id`: level,
  Legend stars, title and pin, the Classic years, the combined record, the
  medal count, and the games the two have played `together`. Reads only; a
  user without a profile row reads as a new player.
  """
  @spec player_sheet(Ecto.UUID.t(), Ecto.UUID.t()) :: map()
  def player_sheet(user_id, viewer_id) do
    profile = Repo.get_by(PlayerProfile, user_id: user_id) || %PlayerProfile{}
    level = Progression.level_for_xp(profile.veteran_xp)
    classic = classic_profile(profile.heritage_flags, nil)

    %{
      level: level,
      prestige: Progression.prestige_for_xp(profile.veteran_xp),
      title: Progression.title_for_level(level),
      pin: pin(profile.heritage_flags),
      classic:
        classic &&
          %{
            username: classic[:name],
            member_since: classic[:member_since],
            games_played: classic[:games_played]
          },
      record: profile |> record(classic || %{}) |> Map.take([:games, :win_rate]),
      medals: user_id |> list_achievements() |> screen_achievements() |> length(),
      together: together(viewer_id, user_id)
    }
  end

  @no_games_together %{games: 0, won_as_partners: 0, against_games: 0, against_won: 0}

  # Completed Pidro 2 games both played, from the viewer's side: on the same
  # team they were partners, otherwise opponents. `against_won` counts the
  # viewer's wins. Two players recorded at one seat (one left, the other took
  # it over) never sat together, so that game does not count.
  defp together(user_id, user_id), do: @no_games_together

  defp together(viewer_id, user_id) do
    from(gs in GameStats,
      # `@>` lets the GIN index on player_ids find the shared games.
      where: fragment("? @> ?", gs.player_ids, type(^[viewer_id, user_id], {:array, Ecto.UUID})),
      select: gs.player_results
    )
    |> Repo.all()
    |> Enum.reduce(@no_games_together, fn results, acc ->
      viewer = get_player_result(%{player_results: results}, viewer_id)
      other = get_player_result(%{player_results: results}, user_id)
      won = if win_from_result?(viewer), do: 1, else: 0

      seat = position_of(viewer)

      case {team_of(viewer), team_of(other), seat != nil and seat == position_of(other)} do
        {nil, _, _} ->
          acc

        {_, nil, _} ->
          acc

        {_, _, true} ->
          acc

        {team, team, false} ->
          %{acc | games: acc.games + 1, won_as_partners: acc.won_as_partners + won}

        _ ->
          %{
            acc
            | games: acc.games + 1,
              against_games: acc.against_games + 1,
              against_won: acc.against_won + won
          }
      end
    end)
  end

  @doc """
  The XP a user earned in completed games since `since` (inclusive), from their
  `GameXp` rows.
  """
  @spec xp_since(Ecto.UUID.t(), DateTime.t()) :: non_neg_integer()
  def xp_since(user_id, %DateTime{} = since) do
    from(x in GameXp,
      where: x.user_id == ^user_id and x.earned_at >= ^since,
      select: coalesce(sum(x.xp), 0)
    )
    |> Repo.one()
  end

  @doc """
  XP earned this week (since Monday 00:00) and this calendar month, both UTC.
  """
  @spec xp_periods(Ecto.UUID.t(), DateTime.t()) :: %{
          this_week: non_neg_integer(),
          this_month: non_neg_integer()
        }
  def xp_periods(user_id, now \\ DateTime.utc_now()) do
    today = DateTime.to_date(now)

    %{
      this_week: xp_since(user_id, start_of_day(Date.beginning_of_week(today))),
      this_month: xp_since(user_id, start_of_day(Date.beginning_of_month(today)))
    }
  end

  defp start_of_day(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  @doc """
  Projects the public, client-facing profile payload (PID-54).

  Takes either a `user_id` or the `get_profile_for_screen/1` screen map and
  returns an **explicit, fail-closed allowlist** of fields safe to serve over
  the API. Skill is exposed ONLY as `%{tier, provisional}` (via
  `Rating.Tier.classify/1`); the raw rating internals and raw accumulators are
  deliberately never carried.

  This is constructed field-by-field — NOT by dropping keys from the screen map
  — so a field added to `get_profile_for_screen/1` later cannot silently leak.

  ## Excluded internals (present in the screen map, ABSENT here)

  `rating_mu`, `rating_sigma`, `rating_games_count` (consumed only to classify
  the tier), `playstyle_bidding_wins`/`playstyle_bidding_attempts` (raw
  accumulators; the derived `playstyle` view replaces them), and `heritage_flags`
  (raw stored map; `heritage` is the public display view).
  """
  @spec public_profile(Ecto.UUID.t() | map()) :: map()
  def public_profile(user_id) when is_binary(user_id) do
    {:ok, screen} = get_profile_for_screen(user_id)
    user = Repo.get!(User, user_id)

    screen
    |> public_profile()
    |> put_classic_claimed_at(user)
    |> Map.merge(%{
      xp: xp_periods(user_id),
      username: user.username,
      display_name: user.display_name,
      bio: user.bio,
      avatar_url:
        PidroServer.Accounts.Avatars.url(
          PidroServer.Accounts.Avatars.metadata_for(user_id),
          user_id
        )
    })
  end

  def public_profile(%{} = screen) do
    %{tier: tier, provisional: provisional} = Rating.Tier.classify(screen)
    classic = classic_profile(screen.heritage_flags, Map.get(screen, :classic_claimed_at))

    %{
      user_id: screen.user_id,
      avatar_url: Map.get(screen, :avatar_url),

      # Headline lifetime stats
      games_played: screen.games_played,
      wins: screen.wins,
      losses: screen.losses,
      win_rate: screen.win_rate,
      first_seen_at: screen.first_seen_at,
      account_age_days: screen.account_age_days,

      # Skill — tier + state ONLY (μ/σ derived away here, never emitted)
      skill: %{tier: tier, provisional: provisional},

      # Veteran (+ uncapped Prestige tail past the L100 cap)
      veteran: %{
        level: screen.veteran_level,
        xp: screen.veteran_xp,
        title: screen.veteran_title,
        progress: encode_progress(screen.veteran_progress),
        prestige: Map.get(screen, :veteran_prestige, 0),
        prestige_progress: encode_prestige_progress(Map.get(screen, :veteran_prestige_progress))
      },

      # Heritage (already a display list)
      heritage: screen.heritage,

      # Classic career. Raw source counters stay private; missing display values
      # are omitted rather than turned into zeroes.
      classic: classic,

      # One record where Classic and Pidro 2 games add up (PID-198).
      record: record(screen, classic || %{}),

      # Playstyle (display view; raw counters NOT carried)
      playstyle: %{
        bidding_win_rate: screen.bidding_win_rate,
        aggression_needle: screen.aggression_needle,
        aggression_label: screen.aggression_label,
        aggression_insufficient: screen.aggression_insufficient,
        avg_winning_bid: screen.avg_winning_bid
      },

      # Mastery
      achievements: screen.achievements,
      achievements_catalog: screen.achievements_catalog
    }
  end

  @doc "Returns the same combined Classic and Pidro 2 record shown on the public profile."
  @spec record(Ecto.UUID.t() | %PlayerProfile{}) :: map()
  def record(%PlayerProfile{} = profile),
    do: record(profile, classic_profile(profile.heritage_flags, nil) || %{})

  def record(user_id),
    do: record(Repo.get_by(PlayerProfile, user_id: user_id) || %PlayerProfile{})

  @doc """
  Counts a solo game start for the ad schedule (PID-123) and uses up the
  player's ad credit, if any: the ad was the ticket for this game. Written off
  the caller's process, like the seat events, so the room manager never waits
  on the database; a failed write is logged and the game goes on.
  """
  @spec count_solo_start(String.t()) :: :ok
  def count_solo_start(user_id) do
    Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
      try do
        {:ok, profile} = get_or_create_profile(user_id)

        Repo.update_all(from(p in PlayerProfile, where: p.id == ^profile.id),
          inc: [solo_games_started: 1],
          set: [ad_credit_expires_at: nil]
        )
      catch
        failure, _reason -> Logger.info("Solo start of #{user_id} not counted: #{failure}")
      end
    end)

    :ok
  end

  defp record(screen, classic) do
    games = screen.games_played + Map.get(classic, :games_played, 0)
    wins = screen.wins + Map.get(classic, :wins, 0)
    losses = screen.losses + Map.get(classic, :losses, 0)

    %{games: games, wins: wins, losses: losses, win_rate: win_rate(wins, games)}
  end

  # Veteran progress is `{into, span} | :max`. JSON cannot encode a tuple, so the
  # pair becomes a 2-element `[into, span]` list and the cap becomes "max".
  defp encode_progress({into, span}), do: [into, span]
  defp encode_progress(:max), do: "max"

  # Prestige progress is `{into, step} | nil`. The tuple becomes a 2-element
  # `[into, step]` list (JSON-safe); below the cap there is no ring, so `nil`
  # passes through as JSON null.
  defp encode_prestige_progress({into, step}), do: [into, step]
  defp encode_prestige_progress(nil), do: nil

  # PID-144 owns the user column. Reading through the struct map keeps this
  # profile code compatible before and after that migration lands.
  defp put_classic_claimed_at(%{classic: classic} = profile, user) when is_map(classic) do
    case user |> Map.from_struct() |> Map.get(:classic_claimed_at) do
      nil -> profile
      claimed_at -> put_in(profile, [:classic, :claimed_at], claimed_at)
    end
  end

  defp put_classic_claimed_at(profile, _user), do: profile

  defp classic_profile(flags, claimed_at) do
    if heritage_value(flags, :played_pidro_one) == true do
      games_played = classic_games_played(flags)
      wins = classic_result(flags, :legacy_victories, :wins)
      losses = classic_result(flags, :legacy_losses, :losses)

      %{
        name: classic_public_name(flags),
        games_played: games_played,
        wins: wins,
        losses: losses,
        win_rate: classic_win_rate(wins, games_played),
        level: heritage_value(flags, :classic_level),
        member_since: heritage_value(flags, :member_since),
        claimed_at: claimed_at
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp classic_public_name(flags) do
    if heritage_value(flags, :classic_name_allowed) == true,
      do: heritage_value(flags, :classic_username)
  end

  defp classic_games_played(flags) do
    old = heritage_value(flags, :legacy_played_games)
    counter = heritage_value(flags, :games_played_counter)

    cond do
      is_integer(old) and is_integer(counter) and counter >= old -> counter
      is_integer(old) and is_integer(counter) -> old + counter
      is_integer(counter) -> counter
      is_integer(old) -> old
      true -> nil
    end
  end

  defp classic_result(flags, old_key, counter_key) do
    old_games = heritage_value(flags, :legacy_played_games)
    counter_games = heritage_value(flags, :games_played_counter)
    old = heritage_value(flags, old_key)
    counter = heritage_value(flags, counter_key)

    cond do
      is_integer(old_games) and is_integer(counter_games) and counter_games >= old_games ->
        counter

      is_integer(old_games) and is_integer(counter_games) ->
        if is_integer(old) and is_integer(counter), do: old + counter

      is_integer(counter_games) ->
        counter

      is_integer(old_games) ->
        old

      true ->
        nil
    end
  end

  defp classic_win_rate(wins, games_played)
       when is_integer(wins) and is_integer(games_played) and games_played > 0,
       do: wins / games_played

  defp classic_win_rate(_wins, _games_played), do: nil

  defp heritage_value(flags, key) when is_map(flags) do
    Map.get(flags, key) || Map.get(flags, Atom.to_string(key))
  end

  defp heritage_value(_flags, _key), do: nil

  # Joins the user's earned rows to the Catalog for display copy, ordered by
  # award time. Unknown keys (a def removed from the catalog) are dropped.
  defp screen_achievements(earned) do
    earned
    |> Enum.sort_by(& &1.awarded_at, DateTime)
    |> Enum.flat_map(fn row ->
      case safe_existing_atom(row.achievement_key) do
        {:ok, key} ->
          def = Enum.find(Catalog.all(), &(&1.key == key))

          if def do
            [
              %{
                key: key,
                name: def.name,
                description: def.description,
                tier: row.tier,
                awarded_at: row.awarded_at
              }
            ]
          else
            []
          end

        :error ->
          []
      end
    end)
  end

  # The active catalog annotated with an `earned` flag (cheap: in-memory data +
  # an already-loaded earned-key set).
  defp screen_catalog(earned_keys) do
    Enum.map(Catalog.active(), fn def ->
      %{
        key: def.key,
        name: def.name,
        description: def.description,
        tier: def.tier,
        earned: MapSet.member?(earned_keys, Atom.to_string(def.key))
      }
    end)
  end

  @doc """
  Arity-2 shim for the lifetime-counter completion hook (PID-44). Delegates with
  empty `scores` + default options so the historical call shape keeps working;
  ratings and XP now move too (see the `/4` doc). With empty scores, XP for these
  callers is `0 + win_bonus` for winners and `0` for losers — production always
  passes real scores from `stats.ex`.
  """
  @spec apply_completed_game(map(), atom() | String.t()) ::
          {:ok, %{optional(Ecto.UUID.t()) => map()}}
  def apply_completed_game(player_results, winner),
    do: apply_completed_game(player_results, winner, %{}, %{}, [])

  @doc """
  Applies one completed game to the participating users' profiles, inside the
  caller's transaction (`Stats.save_completed_game/4`).

  ## Lifetime counters (PID-44)

  Increments `games_played` and either `wins` or `losses` for every key in
  `player_results` that has a user (counters count ALL human participation,
  including `:abandoned` reserved-for ids). Bots never appear (the caller skips
  them). An id with no user, such as a player who deleted their account
  mid-game or a non-UUID, gets no profile or achievement row (KD9); every
  "participant" below means a participant with a user. Rating still sees the
  whole table.

  ## Veteran XP (PID-49) — every completed game, NOT rated-gated

  In the SAME per-participant loop as the counters (dedication, not skill), each
  valid-UUID participant earns `Progression.xp_for_game(team_score, won?)` from
  the per-team `scores` map (`%{north_south: int, east_west: int}`, atom- or
  string-keyed). `veteran_xp` is incremented and `veteran_level` is recomputed
  from the new total. This runs for single-player and bot-filled games too — XP
  is NOT behind `rated_game?/1` (which stays exclusive to the rating block).

  ## Ratings (PID-47) — bot-seat policy (authoritative, v1)

  Rates ONLY Finnish games that started 4 distinct human seats (a full 2v2 of real
  users). Reads each participant's CURRENT stored `{mu, sigma}` as priors via
  `load_priors/1`, calls the shared `rate_game/4`, and on `{:rated, updated}`
  overwrites each participant's `rating_mu`/`rating_sigma` and increments
  `rating_games_count` by 1; on `:unrated` leaves every rating column untouched.

  Single-player / bots-only, 3-human + bot-fill, and any game with fewer than 4
  distinct valid-UUID keys are unrated (lifetime counters still update). This
  falls out of the single shared `rated_game?/1` (reached via `rate_game/3`) —
  no separate flag. `:abandoned` (original human disconnected, bot played under
  their UUID) and `:substitute` seats stay RATED in v1: they still represent 4
  distinct human UUIDs that started the game. Tightening the predicate to exclude
  them is deferred — a one-line change in the single shared `rated_game?/1` that
  both the live and rebuild paths track automatically.

  The per-game move is identical-by-construction to one `rerate_incremental/0`
  replay step (same `rate_game/3`, same priors-at-this-game, count += 1), and so
  matches a fresh `rerate_all/0`. This path does NOT advance the `rating_state`
  cursor — see the cursor-coherence contract in `rerate_incremental/0`'s `@doc`.

  `opts[:game]` is the `GameStats` row just inserted. With it, each participant
  also gets one `GameXp` row for this game (PID-198); without it (older callers
  and tests) only the running total moves.

  `opts[:rule_set]` defaults to `:finnish`. Louisiana games still earn counters
  and XP, but neither live completion nor rerating changes their ratings.

  ## Achievements (PID-50) + the newly-earned-keys return (PID-52 seam)

  After counters/XP/rating, evaluates the active `Catalog` achievements for each
  valid-UUID participant (live `ctx`: post-update aggregates, this game's
  `game_view`, and the user's ordered history incl. this game — the row was
  inserted earlier in this same transaction) and idempotent-upserts the awards.

  The newly-earned keys (those awarded for the FIRST time this call) become the
  `achievements_unlocked` field of each participant's summary (PID-52).

  ## Post-game summary (PID-52) — the new return

  **Returns `{:ok, %{user_id => summary_map}}`** — one ephemeral per-player
  "what changed" map (built by the pure `PostGameSummary.build/3` from a BEFORE
  snapshot read at the top of the loop body + the XP/rating/achievement deltas
  this call computes). Nothing is persisted; the summary is built from
  in-transaction reads and handed back for the caller to push. See
  `PidroServer.Profiles.PostGameSummary` for the shape. There is no rebuild
  concern — `rebuild_*` are untouched.

  ## Playstyle (PID-51) — every completed game, NOT rated-gated

  In the SAME per-participant loop, each valid-UUID participant's bidding facts
  from `player_bidding` (`%{user_id => %{"attempts", "wins", "won_bid_sum"}}`,
  the per-game map built by `Stats.build_player_bidding/2`; string- or atom-keyed
  tolerant, `nil` → no-op) are folded into the four playstyle accumulators
  (`playstyle_bidding_attempts`, `playstyle_bidding_wins`, `avg_winning_bid_sum`,
  `avg_winning_bid_count`). Like XP, playstyle is *character* not skill — it ticks
  for single-player / bot-filled games too. Bot seats never appear as keys in
  `player_bidding`, so bots never pollute a human's accumulators.
  """
  @spec apply_completed_game(map(), atom() | String.t(), map(), map(), keyword()) ::
          {:ok, %{optional(Ecto.UUID.t()) => map()}}
  def apply_completed_game(player_results, winner, scores, player_bidding \\ %{}, opts \\ [])

  def apply_completed_game(player_results, winner, scores, player_bidding, opts)
      when is_map(player_results) do
    player_bidding = if is_map(player_bidding), do: player_bidding, else: %{}
    rule_set = Keyword.get(opts, :rule_set, :finnish)
    game = Keyword.get(opts, :game)
    rated? = match?({:ok, _}, rated_game?(player_results, rule_set))
    players = Map.take(player_results, with_user(Map.keys(player_results)))
    league_game? = PidroServer.Leagues.prepare_game(game, players)

    # 1. Lifetime counters (PID-44) + veteran XP (PID-49) + playstyle (PID-51):
    #    every participant with a user, regardless of rated status. Capture a
    #    single coherent BEFORE snapshot per participant (one read at the top of
    #    the loop body, before the writers run) and the XP delta the writer
    #    already computes — both threaded into the summary later.
    {before_snapshots, xp_deltas} =
      Enum.reduce(Enum.sort_by(players, &elem(&1, 0)), {%{}, %{}}, fn {user_id, result},
                                                                      {befores, xp} ->
        {:ok, before} = get_or_create_profile(user_id)

        apply_one(user_id, win_from_result?(result))
        xp_delta = apply_xp(user_id, result, scores, game)

        if league_game?,
          do: PidroServer.Leagues.credit(user_id, xp_delta.xp_earned, game.completed_at)

        apply_playstyle(user_id, bidding_facts_for(player_bidding, user_id))

        {Map.put(befores, user_id, before_snapshot(before)), Map.put(xp, user_id, xp_delta)}
      end)

    # 2. Ratings (PID-47): rated 4-human games only, priors from stored rows.
    #    Surfaces the per-user before/after μ/σ + counts (empty on :unrated).
    rating_deltas = apply_live_rating(player_results, winner, rule_set)

    # 3. Achievements (PID-50): per participant with a user, evaluate active defs
    #    against the post-update aggregates + this game + ordered history, and
    #    idempotent-upsert. Returns the per-user newly-earned keys.
    histories =
      Map.new(players, fn {user_id, _result} -> {user_id, ordered_history_views(user_id)} end)

    newly_earned = apply_live_achievements(players, player_results, scores, histories)
    partners = partner_summaries(players, player_results, histories)

    # 4. Assemble the ephemeral per-player summary from the deltas just computed.
    summaries =
      Map.new(before_snapshots, fn {valid_id, before} ->
        deltas =
          build_deltas(
            rated?,
            Map.fetch!(xp_deltas, valid_id),
            Map.get(rating_deltas, valid_id),
            Map.get(newly_earned, valid_id, [])
          )
          |> Map.put(:partner, Map.fetch!(partners, valid_id))

        {valid_id, PostGameSummary.build(before, deltas, [])}
      end)

    {:ok, summaries}
  end

  def apply_completed_game(_player_results, _winner, _scores, _player_bidding, _opts),
    do: {:ok, %{}}

  # The BEFORE snapshot of the profile columns the summary classifies against.
  defp before_snapshot(%PlayerProfile{} = profile) do
    %{
      veteran_xp: profile.veteran_xp,
      rating_mu: profile.rating_mu,
      rating_sigma: profile.rating_sigma,
      rating_games_count: profile.rating_games_count
    }
  end

  # Merge the XP, rating, and achievement deltas into the shape PostGameSummary
  # expects. A casual game (or a participant with no rating move) carries
  # `rating_after: nil`.
  defp build_deltas(rated?, %{xp_earned: xp_earned, veteran_xp_after: xp_after}, rating, keys) do
    {rating_after, count_after} =
      case rating do
        %{after: after_rating, count_after: count_after} -> {after_rating, count_after}
        nil -> {nil, nil}
      end

    %{
      xp_earned: xp_earned,
      veteran_xp_after: xp_after,
      rated?: rated? and not is_nil(rating_after),
      rating_after: rating_after,
      rating_count_after: count_after,
      newly_earned_keys: keys
    }
  end

  @doc """
  Recomputes a single user's lifetime counters from `game_stats` history and
  overwrites them.

  Idempotent; reproduces exactly what the incremental path would have produced.
  Tolerates string-keyed JSONB `player_results` on persisted rows.
  """
  @spec rebuild_from_history(Ecto.UUID.t()) ::
          {:ok, PlayerProfile.t()} | {:error, term()}
  def rebuild_from_history(user_id) do
    # Canonical total order (`[asc: completed_at, asc: inserted_at, asc: id]`):
    # the win-streak evaluator needs a stable consecutive ordering, and it must
    # match the order the live path's history query sees so awards stay in parity.
    games =
      from(gs in GameStats,
        where: ^user_id in gs.player_ids,
        order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
      )
      |> Repo.all()

    games_played = length(games)
    wins = Enum.count(games, &won_game?(&1, user_id))
    losses = games_played - wins

    # Veteran XP is a commutative per-game sum, so the rebuild mirrors the live
    # path exactly (same xp_for_game/2 inputs). Order-agnostic, idempotent.
    veteran_xp =
      Enum.reduce(games, 0, fn game, acc -> acc + xp_for_history_game(game, user_id) end)

    # Playstyle accumulators are commutative per-game sums of each row's stored
    # player_bidding facts (string-keyed JSONB tolerant; nil/missing → zero), so
    # the rebuild mirrors the live path exactly. wins == won-bid count, so the
    # avg's count accumulator equals the wins sum.
    playstyle =
      Enum.reduce(
        games,
        %{attempts: 0, wins: 0, won_bid_sum: 0},
        fn game, acc ->
          %{attempts: attempts, wins: wins, won_bid_sum: won_bid_sum} =
            playstyle_facts(bidding_facts_for(game.player_bidding, user_id) || %{})

          %{
            attempts: acc.attempts + attempts,
            wins: acc.wins + wins,
            won_bid_sum: acc.won_bid_sum + won_bid_sum
          }
        end
      )

    with {:ok, profile} <- get_or_create_profile(user_id) do
      result =
        profile
        |> PlayerProfile.changeset(%{
          games_played: games_played,
          wins: wins,
          losses: losses,
          veteran_xp: veteran_xp,
          veteran_level: Progression.level_for_xp(veteran_xp),
          playstyle_bidding_attempts: playstyle.attempts,
          playstyle_bidding_wins: playstyle.wins,
          avg_winning_bid_sum: playstyle.won_bid_sum,
          avg_winning_bid_count: playstyle.wins
        })
        |> Repo.update()

      # Achievements (PID-50): re-award all active defs from the full ordered
      # history. Idempotent (on_conflict: :nothing) and never removes/downgrades
      # — permanence holds even if a def now evaluates false. Same evaluator as
      # the live path; the ctx history is the identical total order, so the
      # earned-key set matches the live path by construction.
      ctx = %{
        user_id: user_id,
        aggregates: %{games_played: games_played, wins: wins},
        this_game: nil,
        history: Enum.map(games, &history_game_view(&1, user_id))
      }

      ctx
      |> Achievements.evaluate_active()
      |> then(&ensure_achievements(user_id, &1))

      result
    end
  end

  @doc """
  Rebuilds every known user's profile from history.

  Collects the distinct set of user ids appearing in `game_stats.player_ids`
  and rebuilds each that still has a user. Returns `{:ok, count}` with the
  number of profiles rebuilt.
  """
  @spec rebuild_all() :: {:ok, non_neg_integer()}
  def rebuild_all do
    user_ids =
      from(gs in GameStats, select: gs.player_ids)
      |> Repo.all()
      |> List.flatten()
      |> Enum.uniq()
      |> with_user()

    Enum.each(user_ids, &rebuild_from_history/1)

    {:ok, length(user_ids)}
  end

  # --- Achievements context (PID-50) ---

  @doc """
  All earned achievement rows for a user (permanent; one per `achievement_key`).
  """
  @spec list_achievements(Ecto.UUID.t()) :: [Achievement.t()]
  def list_achievements(user_id) do
    from(a in Achievement, where: a.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Idempotently awards one achievement to a user.

  Insert with `on_conflict: :nothing` against the unique `[:user_id,
  :achievement_key]` index. Returns `:awarded` when a row was actually inserted
  (newly earned this call) or `:already` when the conflict absorbed it (already
  earned). Permanent — there is no remove/downgrade path.
  """
  @spec award_achievement(Ecto.UUID.t(), atom() | String.t(), pos_integer(), map()) ::
          :awarded | :already
  def award_achievement(user_id, key, tier \\ 1, metadata \\ %{}) do
    now = DateTime.utc_now()

    # insert_all + on_conflict: :nothing gives a reliable affected-row count:
    # 1 when actually inserted (newly earned), 0 when the unique conflict
    # absorbed it (already earned). A plain Repo.insert returns a struct with the
    # client-generated binary_id in BOTH cases, so it cannot distinguish them.
    {count, _} =
      Repo.insert_all(
        Achievement,
        [
          %{
            id: Ecto.UUID.generate(),
            user_id: user_id,
            achievement_key: to_string(key),
            tier: tier,
            awarded_at: now,
            metadata: metadata,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:user_id, :achievement_key]
      )

    if count == 1, do: :awarded, else: :already
  end

  @doc """
  Awards a batch of `{key, tier, metadata}` and returns the list of keys that
  were **newly** awarded (the `:awarded` subset). Used by both the live seam and
  rebuild; re-running with an already-earned set returns `[]`.
  """
  @spec ensure_achievements(Ecto.UUID.t(), [{atom(), pos_integer(), map()}]) :: [atom()]
  def ensure_achievements(user_id, awards) do
    Enum.flat_map(awards, fn {key, tier, metadata} ->
      case award_achievement(user_id, key, tier, metadata) do
        :awarded -> [key]
        :already -> []
      end
    end)
  end

  @doc """
  Pure per-game rating update — the parity seam shared by the rerating job
  (PID-46) and live completion wiring (PID-47).

  Given one game's `player_results` map and `winner`, plus a `prior_ratings` map
  `%{user_id => {mu, sigma}}` for the participating users, returns
  `{:rated, updated_ratings}` where `updated_ratings` is `prior_ratings` with the
  four participants replaced by their new `{mu, sigma}`; or `:unrated` if the game
  is not Finnish or does not satisfy the four-human predicate. The optional
  rule set accepts its internal atom or stored string, defaulting to Finnish.

  Pure: no DB. Tolerates atom- or string-keyed JSONB `player_results`. Missing
  priors default to `Rating.default/0`. The caller owns where priors come from
  (rebuild: an in-memory accumulator; PID-47: the players' stored profile rows).

  Keys in the returned map keep the user-id form as it appears in
  `player_results` (string after a JSONB round-trip).
  """
  @spec rate_game(map(), atom() | String.t(), %{optional(String.t()) => rating()}) ::
          {:rated, %{optional(String.t()) => rating()}} | :unrated
  @spec rate_game(
          map(),
          atom() | String.t(),
          %{optional(String.t()) => rating()},
          atom() | String.t()
        ) ::
          {:rated, %{optional(String.t()) => rating()}} | :unrated
  def rate_game(player_results, winner, prior_ratings, rule_set \\ :finnish) do
    case rated_game?(player_results, rule_set) do
      {:ok, {{team_a, members_a}, {_team_b, members_b}}} ->
        winner_str = normalize_team(winner)

        # Orient teams by the stored winner so the winning roster goes first.
        {winners_ids, losers_ids} =
          if team_a == winner_str do
            {members_a, members_b}
          else
            {members_b, members_a}
          end

        winner_priors = Enum.map(winners_ids, &prior_for(prior_ratings, &1))
        loser_priors = Enum.map(losers_ids, &prior_for(prior_ratings, &1))

        %{winners: new_winners, losers: new_losers} =
          Rating.rate(winner_priors, loser_priors)

        updated =
          prior_ratings
          |> zip_ratings(winners_ids, new_winners)
          |> zip_ratings(losers_ids, new_losers)

        {:rated, updated}

      :error ->
        :unrated
    end
  end

  @doc """
  Wipes every profile's rating to `Rating.default/0` and recomputes it from the
  full `game_stats` history in a fixed total order, seeded from defaults.

  Deterministic and idempotent: re-running produces byte-identical
  `rating_mu`/`rating_sigma`/`rating_games_count`. Runs entirely inside one
  transaction (reset + replay + persist + cursor advance commit atomically).
  Returns `{:ok, %{profiles: persisted_count, games: rated_game_count}}`.
  """
  @spec rerate_all() :: {:ok, %{profiles: non_neg_integer(), games: non_neg_integer()}}
  def rerate_all do
    {default_mu, default_sigma} = Rating.default()

    Repo.transaction(fn ->
      # 1. Reset all ratings to the exact Rating.default/0 (not the rounded
      #    schema default) so replayed values and the accumulator seed match.
      Repo.update_all(PlayerProfile,
        set: [rating_mu: default_mu, rating_sigma: default_sigma, rating_games_count: 0]
      )

      # 2. Replay all games in a deterministic total order from an empty
      #    accumulator (each newly-seen user defaults inside rate_game/3).
      games = Repo.all(ordered_games_query())

      {acc, counts, last_game} =
        Enum.reduce(games, {%{}, %{}, nil}, fn game, {acc, counts, _last} ->
          {acc, counts} = replay_game(game, acc, counts)
          {acc, counts, game}
        end)

      # 3. Persist only touched users (untouched users already hold the reset
      #    default + count 0).
      persist_ratings(acc, counts, :overwrite_count)

      # 4. Advance / clear the cursor.
      set_cursor(last_game)

      %{profiles: map_size(acc), games: counts |> Map.values() |> Enum.sum() |> div(4)}
    end)
  end

  @doc """
  Applies only games completed strictly after the stored composite cursor, using
  the current stored profile ratings as priors, then advances the cursor.

  Equivalent to continuing the `rerate_all/0` accumulator from where it left off:
  the priors at the cursor are exactly the persisted post-cursor-game ratings.
  μ/σ are overwritten; `rating_games_count` is incremented (we are extending, not
  recomputing from zero). Runs inside one transaction.

  Assumes **monotonic `completed_at` arrival** — games are written in roughly
  completion order, so "after the cursor" is the genuinely-new set. A game that
  arrives out of order (a backfill with an old `completed_at`, or a same-second
  tie sorting before the cursor) is skipped; `rerate_all/0` is the authoritative
  repair and re-sorts and replays everything. Same drift-then-rebuild contract as
  the PID-44 counters. Returns `{:ok, %{games: rated_game_count}}`.

  ## Cursor-coherence contract (PID-47)

  Once the live completion path (`apply_completed_game/3`) is active, ratings move
  per game at completion time WITHOUT advancing this cursor (advancing one shared
  `rating_state` row per game-over would serialize every realtime completion on a
  single row lock). The cursor therefore reflects the last BATCH rerate, NOT live
  progress, and lags behind live game completions.

  Consequently `rerate_incremental/0` is a **backfill / repair tool**, not a
  steady-state job. It MUST NOT be run concurrently with (or after, against the
  same games as) live updates: it would re-apply games the live path already
  applied, double-moving μ/σ and double-counting `rating_games_count`.
  **`rerate_all/0` is the source-of-truth repair** once live updates are active —
  it wipes to `Rating.default/0` and replays the full history in total order,
  producing the canonical values regardless of any live/incremental drift.
  """
  @spec rerate_incremental() :: {:ok, %{games: non_neg_integer()}}
  def rerate_incremental do
    Repo.transaction(fn ->
      cursor = load_cursor()
      games = Repo.all(games_after_cursor_query(cursor))

      # Seed the accumulator from CURRENT stored profile ratings for the users
      # in this batch (unseen users default lazily inside rate_game/3).
      batch_user_ids =
        games
        |> Enum.flat_map(&participant_ids/1)
        |> Enum.uniq()

      acc = load_priors(batch_user_ids)

      {acc, counts, last_game} =
        Enum.reduce(games, {acc, %{}, nil}, fn game, {acc, counts, _last} ->
          {acc, counts} = replay_game(game, acc, counts)
          {acc, counts, game}
        end)

      persist_ratings(acc, counts, :increment_count)
      if last_game, do: set_cursor(last_game)

      %{games: counts |> Map.values() |> Enum.sum() |> div(4)}
    end)
  end

  # --- Private helpers ---

  # Pure rated-game predicate. A game is rated iff `player_results` has exactly
  # 4 distinct valid-UUID keys, split 2 per team. Returns
  # `{:ok, {{team_a, [ids]}, {team_b, [ids]}}}` (team strings) or `:error`.
  #
  # PID-47 owns the FINAL policy and may tighten this (e.g. exclude games with
  # any :abandoned / :substitute seat, or guest seats). It is a shared predicate:
  # both the live path and the rebuild must use the same one.
  defp rated_game?(player_results, rule_set \\ :finnish)

  defp rated_game?(_player_results, rule_set) when rule_set not in [:finnish, "finnish"],
    do: :error

  defp rated_game?(player_results, _rule_set) when is_map(player_results) do
    valid =
      Enum.flat_map(player_results, fn {user_id, result} ->
        case Ecto.UUID.cast(user_id) do
          {:ok, _} -> [{user_id, team_of(result)}]
          :error -> []
        end
      end)

    ids = Enum.map(valid, fn {id, _team} -> id end)

    with true <- length(valid) == 4,
         true <- length(Enum.uniq(ids)) == 4,
         [{team_a, members_a}, {team_b, members_b}] <-
           valid
           |> Enum.group_by(fn {_id, team} -> team end, fn {id, _team} -> id end)
           |> Enum.to_list(),
         true <- length(members_a) == 2 and length(members_b) == 2 do
      {:ok, {{team_a, members_a}, {team_b, members_b}}}
    else
      _ -> :error
    end
  end

  defp rated_game?(_player_results, _rule_set), do: :error

  defp team_of(%{team: team}), do: normalize_team(team)
  defp team_of(%{"team" => team}), do: normalize_team(team)
  defp team_of(_result), do: nil

  defp position_of(%{position: position}), do: to_string(position)
  defp position_of(%{"position" => position}), do: to_string(position)
  defp position_of(_result), do: nil

  defp normalize_team(team) when is_atom(team) and not is_nil(team), do: Atom.to_string(team)
  defp normalize_team(team), do: team

  defp prior_for(prior_ratings, user_id) do
    Map.get(prior_ratings, user_id) || Rating.default()
  end

  defp zip_ratings(acc, ids, new_ratings) do
    ids
    |> Enum.zip(new_ratings)
    |> Enum.reduce(acc, fn {id, rating}, acc -> Map.put(acc, id, rating) end)
  end

  defp ordered_games_query do
    from(gs in GameStats, order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id])
  end

  defp games_after_cursor_query(nil), do: ordered_games_query()

  defp games_after_cursor_query({c_at, c_ins, c_id}) do
    from(gs in GameStats,
      where:
        gs.completed_at > ^c_at or
          (gs.completed_at == ^c_at and gs.inserted_at > ^c_ins) or
          (gs.completed_at == ^c_at and gs.inserted_at == ^c_ins and gs.id > ^c_id),
      order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
    )
  end

  # Apply one game through the shared step, bumping per-user counts on a rated
  # game and leaving acc/counts untouched on an unrated one.
  defp replay_game(game, acc, counts) do
    case rate_game(game.player_results, game.winner, acc, game.rule_set) do
      {:rated, updated} ->
        counts =
          game
          |> participant_ids()
          |> Enum.reduce(counts, fn id, counts -> Map.update(counts, id, 1, &(&1 + 1)) end)

        {updated, counts}

      :unrated ->
        {acc, counts}
    end
  end

  # The valid-UUID participant ids of a rated game (empty list for unrated).
  defp participant_ids(game) do
    case rated_game?(game.player_results, Map.get(game, :rule_set, :finnish)) do
      {:ok, {{_team_a, members_a}, {_team_b, members_b}}} -> members_a ++ members_b
      :error -> []
    end
  end

  # Live per-game rating move (PID-47): one rerate_incremental/0-shaped step.
  # Reads the four participants' stored priors, rates via the shared rate_game/3,
  # and on a rated game overwrites μ/σ + increments rating_games_count by 1 for
  # exactly those four ids. On :unrated, nothing is written.
  #
  # Surfaces (PID-52) the per-user after-rating + after-count as
  # `%{user_id => %{after: {mu, sigma}, count_after: n}}` (empty map on
  # :unrated) so the summary can classify the tier move without re-reading.
  defp apply_live_rating(player_results, winner, rule_set) do
    ids = participant_ids(%{player_results: player_results, rule_set: rule_set})
    priors = load_priors(ids)

    case rate_game(player_results, winner, priors, rule_set) do
      {:rated, updated} ->
        # Restrict the persist to the four rated participants so rate_game/3's
        # carried-through non-participant priors are never re-written.
        acc = Map.take(updated, ids)
        counts = Map.new(ids, &{&1, 1})
        persist_ratings(acc, counts, :increment_count)

        counts_after =
          from(p in PlayerProfile,
            where: p.user_id in ^ids,
            select: {p.user_id, p.rating_games_count}
          )
          |> Repo.all()
          |> Map.new()

        Map.new(ids, fn id ->
          {id, %{after: Map.fetch!(acc, id), count_after: Map.get(counts_after, id, 1)}}
        end)

      :unrated ->
        %{}
    end
  end

  # Live achievements (PID-50). For each valid-UUID participant: build the ctx
  # from the post-update aggregates (re-read in this txn), this game's view, and
  # the user's ordered history (incl. this game — already inserted earlier in
  # this transaction), evaluate active defs, and idempotent-upsert. Returns the
  # per-user newly-earned keys as `%{user_id => [key]}`.
  defp apply_live_achievements(players, player_results, scores, histories) do
    players
    |> Enum.reduce(%{}, fn {user_id, result}, acc ->
      case Ecto.UUID.cast(user_id) do
        {:ok, valid_id} ->
          aggregates =
            Repo.one(
              from p in PlayerProfile,
                where: p.user_id == ^valid_id,
                select: %{games_played: p.games_played, wins: p.wins}
            ) || %{games_played: 0, wins: 0}

          this_game = live_game_view(player_results, scores, result, valid_id)

          ctx = %{
            user_id: valid_id,
            aggregates: aggregates,
            this_game: this_game,
            history: Map.fetch!(histories, user_id)
          }

          newly =
            ctx
            |> Achievements.evaluate_active()
            |> then(&ensure_achievements(valid_id, &1))

          if newly == [], do: acc, else: Map.put(acc, valid_id, newly)

        :error ->
          acc
      end
    end)
  end

  # PID-234: each participant's partner in this game and their run together, or
  # nil when the partner is a bot or has no account (guests included). History
  # already holds this game, so `games_together` counts it.
  defp partner_summaries(players, player_results, histories) do
    partner_ids =
      Map.new(players, fn {user_id, _result} ->
        {user_id, partner_id_for(player_results, to_string(user_id))}
      end)

    names =
      from(u in User,
        where: u.id in ^Enum.reject(Map.values(partner_ids), &is_nil/1) and not u.guest
      )
      |> Repo.all()
      |> Map.new(&{&1.id, User.public_name(&1)})

    Map.new(partner_ids, fn {user_id, partner_id} ->
      partner =
        case Map.fetch(names, partner_id) do
          {:ok, name} ->
            history = Map.fetch!(histories, user_id)

            Map.merge(
              %{user_id: partner_id, display_name: name},
              Achievements.partnership_streak(history, partner_id)
            )

          :error ->
            nil
        end

      {user_id, partner}
    end)
  end

  # The user's full ordered history as `game_view`s, in the canonical total
  # order — the same order rebuild_from_history/1 uses, so the streak evaluator
  # sees an identical sequence in both paths.
  defp ordered_history_views(user_id) do
    from(gs in GameStats,
      where: ^user_id in gs.player_ids,
      order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
    )
    |> Repo.all()
    |> Enum.map(&history_game_view(&1, user_id))
  end

  # Build a normalized game_view from the live in-scope data for one participant.
  defp live_game_view(player_results, scores, result, user_id) do
    team = team_from_result(result)
    won? = win_from_result?(result)
    team_score = score_for_team(scores, team)
    opponent_score = score_for_team(scores, opponent_team(team))

    %{
      won?: won?,
      team_score: team_score,
      opponent_score: opponent_score,
      partner_id: partner_id_for(player_results, to_string(user_id))
    }
  end

  # Build a normalized game_view from a persisted GameStats row for one user,
  # reusing the same tolerant team/score/result helpers the counters use.
  defp history_game_view(%GameStats{} = game, user_id) do
    team = team_for_user(game, user_id)
    won? = won_game?(game, user_id)
    team_score = score_for_team(game.final_scores, team)
    opponent_score = score_for_team(game.final_scores, opponent_team(team))

    %{
      won?: won?,
      team_score: team_score,
      opponent_score: opponent_score,
      partner_id: partner_id_for(game.player_results, to_string(user_id))
    }
  end

  # The user's PARTNER in a game: the other valid-UUID human on the SAME team.
  # Derived from the shared rated_game?/1 structure, so a partner is returned
  # ONLY for a true 4-distinct-human 2v2 game (solo/bot-filled → nil). Tolerant
  # of atom- or string-keyed JSONB player_results (rated_game?/1 keeps the key
  # form as it appears, so we compare against the stringified user_id). Returns
  # the partner's user_id string, or nil when there is no real human partner.
  defp partner_id_for(player_results, user_id_str) when is_map(player_results) do
    case rated_game?(player_results) do
      {:ok, {{_team_a, members_a}, {_team_b, members_b}}} ->
        members =
          cond do
            user_id_str in normalize_ids(members_a) -> members_a
            user_id_str in normalize_ids(members_b) -> members_b
            true -> []
          end

        members
        |> Enum.map(&to_string/1)
        |> Enum.find(&(&1 != user_id_str))

      :error ->
        nil
    end
  end

  defp partner_id_for(_player_results, _user_id_str), do: nil

  defp normalize_ids(ids), do: Enum.map(ids, &to_string/1)

  defp opponent_team(team) do
    case normalize_team(team) do
      "north_south" -> "east_west"
      "east_west" -> "north_south"
      _ -> nil
    end
  end

  @doc """
  Loads stored `{mu, sigma}` priors for the given user ids as a
  `%{user_id => {mu, sigma}}` map. Pure read; creates no rows. Shared by the
  incremental rerate job and the live completion path so both see identical
  priors-at-this-game.

  Only users who have actually been RATED (`rating_games_count > 0`) contribute a
  prior. Users with no row — or a lazily-created counter-only row that has never
  been rated — are omitted, so callers default them to the EXACT `Rating.default/0`
  inside `rate_game/3`. This is what makes the live path identical-by-construction
  to a from-scratch `rerate_all/0`: the rounded schema-default `rating_sigma`
  (8.333) on an unrated row never leaks in as a prior in place of `Rating.default/0`
  (8.333…).
  """
  @spec load_priors([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => rating()}
  def load_priors(user_ids) do
    from(p in PlayerProfile,
      where: p.user_id in ^user_ids and p.rating_games_count > 0,
      select: {p.user_id, p.rating_mu, p.rating_sigma}
    )
    |> Repo.all()
    |> Map.new(fn {user_id, mu, sigma} -> {user_id, {mu, sigma}} end)
  end

  # Overwrite each touched user's μ/σ; either overwrite the count (full rebuild)
  # or increment it (incremental). Lazily creates a profile row if absent.
  defp persist_ratings(acc, counts, count_mode) do
    acc
    |> Map.take(with_user(Map.keys(acc)))
    |> Enum.each(fn {user_id, {mu, sigma}} ->
      {:ok, _profile} = get_or_create_profile(user_id)
      count = Map.get(counts, user_id, 0)

      set =
        case count_mode do
          :overwrite_count -> [rating_mu: mu, rating_sigma: sigma, rating_games_count: count]
          :increment_count -> [rating_mu: mu, rating_sigma: sigma]
        end

      query = from(p in PlayerProfile, where: p.user_id == ^user_id)

      case count_mode do
        :overwrite_count -> Repo.update_all(query, set: set)
        :increment_count -> Repo.update_all(query, set: set, inc: [rating_games_count: count])
      end
    end)
  end

  # KD9: of a deleted player only `game_stats` and `abandonment_events` keep the
  # bare id, so profile and achievement rows are written only for the ids that
  # still have a user.
  defp with_user(ids) do
    uuids = for id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], into: %{}, do: {id, uuid}
    known = MapSet.new(Repo.all(from u in User, where: u.id in ^Map.values(uuids), select: u.id))
    for {id, uuid} <- uuids, MapSet.member?(known, uuid), do: id
  end

  # --- Cursor ---

  defp load_cursor do
    case Repo.get(RatingState, RatingState.singleton_id()) do
      %RatingState{last_completed_at: nil} ->
        nil

      %RatingState{last_game_id: nil} ->
        nil

      %RatingState{} = state ->
        {state.last_completed_at, state.last_inserted_at, state.last_game_id}

      nil ->
        nil
    end
  end

  defp set_cursor(nil) do
    upsert_cursor(%{last_completed_at: nil, last_inserted_at: nil, last_game_id: nil})
  end

  defp set_cursor(%GameStats{} = game) do
    upsert_cursor(%{
      last_completed_at: game.completed_at,
      last_inserted_at: game.inserted_at,
      last_game_id: game.id
    })
  end

  defp upsert_cursor(attrs) do
    state =
      Repo.get(RatingState, RatingState.singleton_id()) ||
        %RatingState{id: RatingState.singleton_id()}

    state
    |> RatingState.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp apply_one(user_id, won?) do
    {:ok, _profile} = get_or_create_profile(user_id)

    increments =
      if won? do
        [games_played: 1, wins: 1]
      else
        [games_played: 1, losses: 1]
      end

    from(p in PlayerProfile, where: p.user_id == ^user_id)
    |> Repo.update_all(inc: increments)

    :ok
  end

  # Live XP writer (PID-49), inside the surrounding completion transaction.
  # Increments veteran_xp by the per-game award, then recomputes the
  # veteran_level cache from the post-inc total. The XP inc is commutative; the
  # level set is a pure function of the new XP. Surfaces the per-game delta +
  # after-total so the summary (PID-52) needs no re-read. With the game row, the
  # same delta is also recorded per game (PID-198).
  defp apply_xp(user_id, result, scores, game) do
    won? = win_from_result?(result)
    team_score = team_score_for(result, scores)
    delta = Progression.xp_for_game(team_score, won?)
    {:ok, _profile} = get_or_create_profile(user_id)

    from(p in PlayerProfile, where: p.user_id == ^user_id)
    |> Repo.update_all(inc: [veteran_xp: delta])

    new_xp =
      Repo.one(from p in PlayerProfile, where: p.user_id == ^user_id, select: p.veteran_xp)

    from(p in PlayerProfile, where: p.user_id == ^user_id)
    |> Repo.update_all(set: [veteran_level: Progression.level_for_xp(new_xp)])

    record_game_xp(user_id, delta, game)

    %{xp_earned: delta, veteran_xp_after: new_xp}
  end

  defp record_game_xp(_user_id, _delta, nil), do: :ok

  defp record_game_xp(user_id, delta, %GameStats{id: game_id, completed_at: completed_at}) do
    Repo.insert!(
      %GameXp{user_id: user_id, game_stats_id: game_id, xp: delta, earned_at: completed_at},
      on_conflict: :nothing,
      conflict_target: [:user_id, :game_stats_id]
    )

    :ok
  end

  # Live playstyle writer (PID-51), inside the surrounding completion
  # transaction. Folds one game's per-user bidding facts into the four
  # accumulators (commutative per-game sums → live == rebuild). A nil/absent
  # facts map (no bidding facts for this user) is a no-op.
  defp apply_playstyle(_user_id, nil), do: :ok

  defp apply_playstyle(user_id, facts) when is_map(facts) do
    %{attempts: attempts, wins: wins, won_bid_sum: won_bid_sum} = playstyle_facts(facts)

    if attempts == 0 and wins == 0 and won_bid_sum == 0 do
      :ok
    else
      {:ok, _profile} = get_or_create_profile(user_id)

      from(p in PlayerProfile, where: p.user_id == ^user_id)
      |> Repo.update_all(
        inc: [
          playstyle_bidding_attempts: attempts,
          playstyle_bidding_wins: wins,
          avg_winning_bid_sum: won_bid_sum,
          # wins == won-bid count, so the avg's count accumulator is fed from wins.
          avg_winning_bid_count: wins
        ]
      )
    end

    :ok
  end

  defp apply_playstyle(_user_id, _facts), do: :ok

  # Resolve a user's per-game bidding facts from the player_bidding map,
  # tolerating atom (just-built) or string (JSONB round-trip) user-id keys.
  defp bidding_facts_for(player_bidding, user_id) when is_map(player_bidding) do
    Map.get(player_bidding, user_id) || Map.get(player_bidding, to_string(user_id))
  end

  defp bidding_facts_for(_player_bidding, _user_id), do: nil

  # Normalize a per-user facts map (atom- or string-keyed; missing/non-integer
  # → 0) into the three accumulator deltas.
  defp playstyle_facts(facts) when is_map(facts) do
    %{
      attempts: facts_int(facts, :attempts, "attempts"),
      wins: facts_int(facts, :wins, "wins"),
      won_bid_sum: facts_int(facts, :won_bid_sum, "won_bid_sum")
    }
  end

  defp facts_int(facts, atom_key, string_key) do
    value = Map.get(facts, atom_key) || Map.get(facts, string_key)
    if is_integer(value), do: value, else: 0
  end

  # Per-game XP contribution for the rebuild: reuses won_game?/2 for the win
  # bonus and reads the user's team score from the stored final_scores
  # (string-keyed JSONB tolerant). Legacy rows missing a team's score floor to 0.
  defp xp_for_history_game(%GameStats{} = game, user_id) do
    won? = won_game?(game, user_id)
    team = team_for_user(game, user_id)
    team_score = score_for_team(game.final_scores, team)
    Progression.xp_for_game(team_score, won?)
  end

  # Live path: read scores[result.team], tolerating atom/string keys on both the
  # result map's team and the scores map. Defaults to 0 when absent.
  defp team_score_for(result, scores) do
    score_for_team(scores, team_from_result(result))
  end

  defp team_from_result(%{team: team}), do: team
  defp team_from_result(%{"team" => team}), do: team
  defp team_from_result(_result), do: nil

  # Rebuild path: the user's team from the stored result, with the same
  # position-vs-player_ids fallback won_game?/2 uses for legacy rows.
  defp team_for_user(game, user_id) do
    case get_player_result(game, user_id) do
      %{team: team} ->
        team

      %{"team" => team} ->
        team

      _ ->
        case get_player_position(game, user_id) do
          pos when pos in [:north, :south] -> :north_south
          pos when pos in [:east, :west] -> :east_west
          _ -> nil
        end
    end
  end

  # Tolerant team-score read: atom OR string team key against an atom- OR
  # string-keyed scores map. Non-integer / absent values floor to 0.
  defp score_for_team(scores, team) when is_map(scores) and not is_nil(team) do
    value =
      Map.get(scores, team) ||
        Map.get(scores, to_string(team)) ||
        atom_keyed_score(scores, team)

    if is_integer(value), do: value, else: 0
  end

  defp score_for_team(_scores, _team), do: 0

  # When `team` is a string (JSONB result) but `scores` is atom-keyed (in-memory).
  defp atom_keyed_score(scores, team) when is_binary(team) do
    case safe_existing_atom(team) do
      {:ok, atom} -> Map.get(scores, atom)
      :error -> nil
    end
  end

  defp atom_keyed_score(_scores, _team), do: nil

  defp safe_existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  # Incremental path: atom-keyed in-memory result map built by
  # Stats.build_player_results/3.
  defp win_from_result?(%{result: :win}), do: true
  defp win_from_result?(%{result: "win"}), do: true
  defp win_from_result?(%{"result" => "win"}), do: true
  defp win_from_result?(%{"result" => :win}), do: true
  defp win_from_result?(_result), do: false

  # Rebuild path: persisted GameStats with string-keyed JSONB player_results.
  # An explicitly-stored result (win OR loss) is authoritative; only rows with
  # NO recorded result (legacy rows written before player_results existed) fall
  # back to position-vs-winner inference. The fallback relies on player_ids
  # order, which is unreliable for modern rows whose player_ids come from an
  # unordered map — so it must never be reached when a result is present.
  defp won_game?(%GameStats{} = game, user_id) do
    case get_player_result(game, user_id) do
      %{result: :win} -> true
      %{"result" => "win"} -> true
      %{result: :loss} -> false
      %{"result" => "loss"} -> false
      _ -> won_game_by_position?(game, user_id)
    end
  end

  defp won_game_by_position?(%GameStats{} = game, user_id) do
    winner = game.winner
    position = get_player_position(game, user_id)

    case {winner, position} do
      {:north_south, pos} when pos in [:north, :south] -> true
      {:east_west, pos} when pos in [:east, :west] -> true
      {"north_south", pos} when pos in [:north, :south] -> true
      {"east_west", pos} when pos in [:east, :west] -> true
      _ -> false
    end
  end

  defp get_player_result(%{player_results: player_results}, user_id)
       when is_map(player_results) do
    Map.get(player_results, user_id) || Map.get(player_results, to_string(user_id))
  end

  defp get_player_result(_game, _user_id), do: nil

  defp get_player_position(game, user_id) do
    player_ids = game.player_ids || []

    case Enum.find_index(player_ids, &(&1 == user_id)) do
      0 -> :north
      1 -> :east
      2 -> :south
      3 -> :west
      _ -> nil
    end
  end

  defp win_rate(_wins, 0), do: 0.0
  defp win_rate(wins, games_played), do: wins / games_played

  defp first_seen_at(user_id) do
    case Repo.get(User, user_id) do
      %User{inserted_at: inserted_at} -> inserted_at
      nil -> nil
    end
  end

  defp account_age_days(nil), do: nil

  defp account_age_days(%DateTime{} = first_seen_at) do
    DateTime.diff(DateTime.utc_now(), first_seen_at, :day)
  end
end

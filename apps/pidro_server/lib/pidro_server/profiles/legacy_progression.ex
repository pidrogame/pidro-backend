defmodule PidroServer.Profiles.LegacyProgression do
  @moduledoc """
  The input contract for the Pidro 1 → Pidro 2 progression carry-over (PID-53).

  A plain data struct (no Ecto, no DB) describing the pre-aggregated legacy
  progression the bridge/claim flow hands to `Profiles.import_legacy_progression/2`.
  Defining it here documents the shape in one place, gives the mapping a single
  typed input to pattern-match, and gives the future bridge a named build target.

  Every optional field defaults so "nil/missing tolerated" is structural rather
  than scattered `Map.get/2` calls. The only field the bridge must supply is
  `:xp`; the rest degrade gracefully when absent.

  ## Fields

    * `xp` — lifetime legacy XP (`users.xp`). The only field needed for the
      Veteran level/title; kept verbatim. Defaults to `0` (→ level 1).
    * `classic_user_id`, `classic_username`, and `classic_level` — the Classic
      account's immutable id and profile identity.
    * `legacy_played_games`, `legacy_victories`, and `legacy_losses` — the
      oldest counters frozen in 2016.
    * `games_played_counter`, `wins`, and `losses` — the counters used from
      December 2016 onward.
    * `games_logged` — number of XP-log rows since 2018. It is retained for
      auditing, never added to games played.
    * `games_started` and `games_ended` — fair-play row counts. They are
      retained for auditing, never added to games played.
    * `member_since` — the Classic account creation date.
    * `badges` — opaque legacy accolade names (`user_badges.AchievementData`),
      routed to the display-only `legacy_accolades` Heritage flag.
    * `premium` — the bridge's active-premium decision (`now < users.premium_until`).
      Recorded as a display-only Heritage flag (Pidro 2 has no entitlement system).
      Missing values stay `nil`, distinct from a known `false` value.
    * `founding_member` — pre-launch cohort flag (display only). Default `false`.
    * `playstyle` — pre-aggregated bidding facts (`bidding_attempts`,
      `bidding_wins`, `won_bid_sum`) from `game_play_data.RoomData`, or `nil`
      when unavailable. `won_bid_count == bidding_wins` (a winning bid is a won
      round), so there is no separate count. Default `nil`.

  Both a `%LegacyProgression{}` and a plain map are accepted by
  `import_legacy_progression/2` (a map is normalized via `struct/2`).
  """

  @type playstyle :: %{
          bidding_attempts: non_neg_integer(),
          bidding_wins: non_neg_integer(),
          won_bid_sum: non_neg_integer()
        }

  @type t :: %__MODULE__{
          xp: non_neg_integer(),
          classic_user_id: integer() | nil,
          classic_username: String.t() | nil,
          classic_name_allowed: boolean() | nil,
          classic_level: non_neg_integer() | nil,
          legacy_played_games: non_neg_integer() | nil,
          legacy_victories: non_neg_integer() | nil,
          legacy_losses: non_neg_integer() | nil,
          games_played_counter: non_neg_integer() | nil,
          wins: non_neg_integer() | nil,
          losses: non_neg_integer() | nil,
          games_logged: non_neg_integer() | nil,
          games_started: non_neg_integer() | nil,
          games_ended: non_neg_integer() | nil,
          member_since: String.t() | nil,
          badges: [String.t()] | nil,
          premium: boolean() | nil,
          founding_member: boolean(),
          playstyle: playstyle() | nil
        }

  defstruct xp: 0,
            classic_user_id: nil,
            classic_username: nil,
            classic_name_allowed: nil,
            classic_level: nil,
            legacy_played_games: nil,
            legacy_victories: nil,
            legacy_losses: nil,
            games_played_counter: nil,
            wins: nil,
            losses: nil,
            games_logged: nil,
            games_started: nil,
            games_ended: nil,
            member_since: nil,
            badges: nil,
            premium: nil,
            founding_member: false,
            playstyle: nil

  @doc "Builds the typed importer input from trusted atom-keyed data or a JSON map."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    defaults = Map.from_struct(%__MODULE__{})

    values =
      Enum.reduce(Map.keys(defaults), %{}, fn key, acc ->
        value =
          Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), Map.fetch!(defaults, key)))

        Map.put(acc, key, if(is_nil(value), do: Map.fetch!(defaults, key), else: value))
      end)
      |> Map.update!(:xp, &non_negative_xp/1)

    struct!(__MODULE__, values)
  end

  # Classic can leave a player below zero after a lost first game (seen down
  # to -28); the Veteran level counts that as 0 XP.
  defp non_negative_xp(xp) when is_integer(xp) and xp < 0, do: 0
  defp non_negative_xp(xp), do: xp
end

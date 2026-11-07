defmodule PidroServer.Profiles.PlayerProfile do
  @moduledoc """
  Per-user profile + progression rollup.

  One row per user, created lazily. Holds lifetime play counters (maintained
  incrementally on game completion, rebuildable from game_stats history) plus
  progression columns that later tickets compute (rating, veteran, playstyle,
  heritage). PID-44 only owns the lifetime counters; progression columns ship
  with defaults and are written by PID-45..PID-51.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "player_profiles" do
    # Owner. Loose binary_id (no FK) to mirror game_stats.player_ids, which
    # deliberately has no users FK and whose deletes do not cascade.
    field :user_id, :binary_id

    # --- Lifetime counters (PID-44 owns these) ---
    field :games_played, :integer, default: 0
    field :wins, :integer, default: 0
    field :losses, :integer, default: 0
    # win_rate is DERIVED (wins / games_played) at read time — not stored.
    # first_seen_at derives from users.inserted_at — not stored.

    # --- Rating (PID-45/47 compute; PID-44 defaults only) ---
    field :rating_mu, :float, default: 25.0
    field :rating_sigma, :float, default: 8.333
    field :rating_games_count, :integer, default: 0

    # --- Veteran / XP (PID-49 computes; PID-44 defaults only) ---
    field :veteran_level, :integer, default: 0
    field :veteran_xp, :integer, default: 0

    # --- Playstyle (PID-51 computes; PID-44 defaults only) ---
    field :playstyle_bidding_wins, :integer, default: 0
    field :playstyle_bidding_attempts, :integer, default: 0
    field :avg_winning_bid_sum, :integer, default: 0
    field :avg_winning_bid_count, :integer, default: 0

    # --- Heritage (PID-49 computes; PID-44 defaults only) ---
    field :heritage_flags, :map, default: %{}

    # --- Ads (PID-123): the ad schedule's cadence and a watched ad's credit ---
    field :solo_games_started, :integer, default: 0
    field :ad_credit_expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @castable [
    :user_id,
    :games_played,
    :wins,
    :losses,
    :rating_mu,
    :rating_sigma,
    :rating_games_count,
    :veteran_level,
    :veteran_xp,
    :playstyle_bidding_wins,
    :playstyle_bidding_attempts,
    :avg_winning_bid_sum,
    :avg_winning_bid_count,
    :heritage_flags
  ]

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @castable)
    |> validate_required([:user_id])
    |> validate_number(:games_played, greater_than_or_equal_to: 0)
    |> validate_number(:wins, greater_than_or_equal_to: 0)
    |> validate_number(:losses, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id)
  end
end

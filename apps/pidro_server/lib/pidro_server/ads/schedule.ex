defmodule PidroServer.Ads.Schedule do
  @moduledoc """
  When a solo game needs an ad, as a pure function of the admin values
  (`PidroServer.Settings.ads/0`), the player's finished games in this app
  (`player_profiles.games_played`; the Classic record never counts) and the
  solo games they have started.

  No ad while `total_games < ads_free_games`. After that the next solo start,
  number `solo_games_started + 1`, needs one when it is a multiple of
  `ads_early_every_n`, and once `solo_games_started >= ads_games_until_steady`
  a multiple of `ads_steady_every_n`. With 10 / 3 / 40 / 2: the 3rd, 6th, ...
  39th solo starts, then the 42nd, 44th, ...
  """

  @doc "Whether the next solo game needs an ad."
  @spec needs_ad?(PidroServer.Settings.ads(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def needs_ad?(%{ads_free_games: free}, total_games, _solo) when total_games < free, do: false
  def needs_ad?(settings, _total_games, solo), do: rem(solo + 1, every_n(settings, solo)) == 0

  @doc """
  How many solo games can start before the one that needs an ad, counting each
  as a finished game too; 0 when the next one needs it.
  """
  @spec games_until_ad(PidroServer.Settings.ads(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def games_until_ad(settings, total_games, solo) do
    # The free games have no ad, so the search starts after them.
    max(settings.ads_free_games - total_games, 0)
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find(&needs_ad?(settings, total_games + &1, solo + &1))
  end

  defp every_n(%{ads_games_until_steady: steady, ads_steady_every_n: n}, solo)
       when solo >= steady,
       do: n

  defp every_n(%{ads_early_every_n: n}, _solo), do: n
end

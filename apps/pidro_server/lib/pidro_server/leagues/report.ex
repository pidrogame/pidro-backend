defmodule PidroServer.Leagues.Report do
  @moduledoc "League operations numbers, aggregated without per-player reads."
  import Ecto.Query
  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Leagues
  alias PidroServer.Leagues.{Membership, Player, Result, Room}
  alias PidroServer.Repo

  @doc "Current rooms, movement, distribution, participation and repeated pairings."
  def build(now \\ DateTime.utc_now()) do
    {starts, closes} = Leagues.week(now)
    previous = DateTime.add(starts, -604_800)

    rooms =
      Repo.all(
        from r in Room,
          left_join: m in Membership,
          on: m.room_id == r.id,
          where: r.closes_at == ^closes,
          group_by: [r.id, r.league],
          order_by: r.league,
          select: %{
            id: r.id,
            league: r.league,
            members: count(m.id),
            oldest: min(m.placed_at),
            newest: max(m.placed_at)
          }
      )

    distribution =
      Repo.all(
        from u in User,
          left_join: p in Player,
          on: p.user_id == u.id,
          where: not u.guest,
          group_by: fragment("COALESCE(?, 'deuce')", p.league),
          select: {fragment("COALESCE(?, 'deuce')", p.league), count(u.id)}
      )
      |> Map.new()

    last = Repo.one(from w in "league_weeks", select: type(max(w.closes_at), :utc_datetime))

    movement =
      if last do
        Repo.all(
          from r in Result,
            where: r.week_closes_at == ^last,
            group_by: [r.old_league, r.move],
            select: {{r.old_league, r.move}, count(r.id)}
        )
        |> Map.new()
      else
        %{}
      end

    %{
      on: Leagues.enabled?(now),
      since: Leagues.start_at(),
      starts_at: starts,
      closes_at: closes,
      rooms: rooms,
      distribution: distribution,
      total: Enum.sum(Map.values(distribution)),
      last_close: last,
      movement: movement,
      participation: participation(previous, starts),
      pairs: pairs(starts, closes)
    }
  end

  defp participation(starts, closes) do
    %{rows: [[played, placed]]} =
      Repo.query!(
        """
        WITH played AS (
          SELECT DISTINCT unnest(player_ids) AS user_id FROM game_stats
          WHERE completed_at >= $1 AND completed_at < $2
        ), placed AS (
          SELECT user_id FROM league_memberships WHERE closes_at = $2
          UNION SELECT user_id FROM league_results WHERE week_closes_at = $2
        )
        SELECT count(*), count(placed.user_id) FROM played LEFT JOIN placed USING (user_id)
        """,
        [DateTime.to_naive(starts), DateTime.to_naive(closes)]
      )

    %{
      played: played,
      placed: placed,
      percent: if(played == 0, do: 0.0, else: Float.round(100 * placed / played, 1))
    }
  end

  defp pairs(starts, closes) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH shared_games AS (
          SELECT a, b, g.player_results -> a::text AS player_a, g.player_results -> b::text AS player_b
          FROM game_stats g, LATERAL unnest(g.player_ids) a, LATERAL unnest(g.player_ids) b
          WHERE g.completed_at >= $1 AND g.completed_at < $2 AND a < b
        )
        SELECT a::text, b::text, count(*),
               count(*) FILTER (WHERE player_a ->> 'team' = player_b ->> 'team'),
               count(*) FILTER (WHERE player_a ->> 'team' <> player_b ->> 'team')
        FROM shared_games
        -- Exclude a player and their replacement; older games may lack seat data.
        WHERE (player_a ->> 'position' = player_b ->> 'position') IS NOT TRUE
        GROUP BY a, b HAVING count(*) > 10 ORDER BY count(*) DESC, a, b
        """,
        [DateTime.to_naive(starts), DateTime.to_naive(closes)]
      )

    users =
      rows |> Enum.flat_map(fn [a, b | _] -> [a, b] end) |> Enum.uniq() |> Auth.get_users_map()

    Enum.map(rows, fn [a, b, games, teammates, opponents] ->
      %{
        players: Enum.map([a, b], &pair_player(&1, users[&1])),
        games: games,
        teammates: teammates,
        opponents: opponents,
        unknown: games - teammates - opponents
      }
    end)
  end

  defp pair_player(id, nil), do: %{id: id, name: nil, avatar_url: nil}

  defp pair_player(id, user) do
    %{id: id, name: User.public_name(user), avatar_url: user.avatar_url, level: user.level}
  end
end

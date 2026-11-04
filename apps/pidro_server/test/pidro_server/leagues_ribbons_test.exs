defmodule PidroServer.LeaguesRibbonsTest do
  use ExUnit.Case, async: true
  alias PidroServer.Leagues.Ribbons

  test "best played or earned league wins; skipped weeks lose the star" do
    closes = Ribbons.closes("2026-10")

    rows =
      for {at, i} <- Enum.with_index(closes),
          do: %{
            week_closes_at: at,
            old_league: "ten",
            new_league: if(i == 2, do: "jack", else: "ten")
          }

    now = ~U[2026-11-04 12:00:00Z]

    assert %{league: "jack", star: true, weeks_played: 4, weeks_total: 4, star_possible: false} =
             Ribbons.ribbon(rows, "2026-10", now)

    assert %{league: "jack", star: false, weeks_played: 3} =
             Ribbons.ribbon(tl(rows), "2026-10", now)

    assert Ribbons.ribbon([], "2026-10", now) == nil
  end

  test "current participation is deduplicated; elapsed closes decide star possibility" do
    [first, second | _] = Ribbons.closes("2026-11")
    row = %{week_closes_at: first, old_league: "ten", new_league: "jack"}

    assert %{weeks_played: 2, weeks_total: 5, so_far: true, star_possible: true} =
             Ribbons.ribbon([row], "2026-11", ~U[2026-11-04 12:00:00Z], {second, "jack"})

    assert %{weeks_played: 1, star_possible: false} =
             Ribbons.ribbon([], "2026-11", ~U[2026-11-04 12:00:00Z], {second, "jack"})

    assert %{weeks_played: 1} = Ribbons.ribbon([row], "2026-11", first, {first, "ten"})
  end
end

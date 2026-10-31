defmodule PidroServer.Stats.BetaReportTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.AccountsFixtures
  alias PidroServer.GameArchive.Archive
  alias PidroServer.Stats.{AbandonmentEvent, BetaReport, GameStats, SeatEvent}

  # Range 10-16 October 2026; everything outside it must not count.
  @from ~D[2026-10-10]
  @to ~D[2026-10-16]
  @today ~D[2026-10-31]

  setup do
    a = classic(AccountsFixtures.user_fixture(), 501)
    b = classic(AccountsFixtures.user_fixture(), 502)
    g = AccountsFixtures.user_fixture(%{guest: true})
    # A player who has played and whose account was deleted since.
    d = Ecto.UUID.generate()
    # A Classic player who never played here.
    classic(AccountsFixtures.user_fixture(), 503)

    finished("finnish", ~U[2026-10-05 12:00:00Z], [b.id])
    finished("finnish", ~U[2026-10-10 12:00:00Z], [a.id, g.id])
    finished("finnish", ~U[2026-10-11 09:00:00Z], [a.id])
    finished("louisiana", ~U[2026-10-12 20:00:00Z], [g.id, d])
    finished("finnish", ~U[2026-10-20 12:00:00Z], [b.id])

    archive("complete", "finnish", ~U[2026-10-10 11:00:00Z], [a.id, :bot, g.id, :bot])
    archive("closed", "finnish", ~U[2026-10-13 10:00:00Z], [b.id, :bot, :bot, :bot])
    archive("interrupted", "louisiana", ~U[2026-10-14 10:00:00Z], [a.id, g.id, d, :bot])
    archive("closed", "louisiana", ~U[2026-10-16 23:59:00Z], [a.id, :bot, :bot, :bot])
    archive("closed", "finnish", ~U[2026-10-17 00:00:00Z], [g.id, :bot, :bot, :bot])

    seat(a.id, "drop", nil, ~N[2026-10-11 10:00:00])
    seat(a.id, "return", nil, ~N[2026-10-11 10:00:30])
    seat(a.id, "drop", nil, ~N[2026-10-12 10:00:00])
    seat(g.id, "drop", nil, ~N[2026-10-13 10:00:00])
    seat(a.id, "turn", 4_000, ~N[2026-10-10 11:01:00])
    seat(a.id, "turn", 6_000, ~N[2026-10-10 11:02:00])
    seat(g.id, "turn", 20_000, ~N[2026-10-10 11:03:00])
    seat(g.id, "timeout", 30_000, ~N[2026-10-10 11:04:00])
    seat(d, "turn", 10_000, ~N[2026-10-14 10:05:00])
    seat(a.id, "turn", 1, ~N[2026-10-17 00:00:00])
    seat(g.id, "timeout", 30_000, ~N[2026-10-09 23:59:59])

    abandoned(g.id, ~N[2026-10-13 10:30:00])
    abandoned(d, ~N[2026-10-14 10:30:00])
    abandoned(b.id, ~N[2026-10-21 10:30:00])

    %{report: BetaReport.build(@from, @to, @today), a: a, g: g}
  end

  defp counts(accounts, guests, all), do: %{accounts: accounts, guests: guests, all: all}

  test "players who played in the range, split by the guest flag", %{report: report} do
    # a, b and g, plus the deleted player, who counts under All only.
    assert report.players == counts(2, 1, 4)
  end

  test "games finished and ended early, per rule set", %{report: report} do
    [finnish, louisiana] = report.rule_sets

    assert finnish.rule_set == "finnish"
    # A table with an account and a guest counts in both columns, once in All.
    assert finnish.finished == counts(2, 1, 2)
    assert finnish.closed == counts(1, 0, 1)
    assert finnish.interrupted == counts(0, 0, 0)

    assert louisiana.rule_set == "louisiana"
    assert louisiana.finished == counts(0, 1, 1)
    assert louisiana.closed == counts(1, 0, 1)
    assert louisiana.interrupted == counts(1, 1, 1)
  end

  test "the promise: drops, returns, takeovers and computer seats", %{report: report} do
    assert report.drops == counts(2, 1, 3)
    assert report.returns == counts(1, 0, 1)
    assert report.takeovers == counts(0, 1, 2)
    assert report.games_started == counts(4, 2, 4)
    # 2 + 3 + 1 + 3 computer seats at the start of the four games.
    assert report.computer_seats == counts(9, 3, 9)
  end

  test "pace: timed turns, timeouts and the median time per turn", %{report: report} do
    assert report.timed_turns == counts(2, 2, 5)
    assert report.timeouts == counts(0, 1, 1)
    assert report.median_turn_ms == %{accounts: 5_000, guests: 25_000, all: 10_000}
  end

  test "return on day 2 and day 7 for players whose first day is in the range",
       %{report: report} do
    # a: 10th, 11th, 14th, 16th (back on both); g: 10th, 12th, 14th (neither);
    # the deleted player: 12th, 14th (neither). b first played on the 5th.
    assert report.new_players == counts(1, 1, 3)
    assert report.day2 == %{returned: counts(1, 0, 1), due: counts(1, 1, 3)}
    assert report.day7 == %{returned: counts(1, 0, 1), due: counts(1, 1, 3)}
  end

  test "a day that is not over yet is due only for players already back on it" do
    report = BetaReport.build(@from, ~D[2026-10-10], ~D[2026-10-11])

    # a is back on the 11th; g is not, and the 11th is still today.
    assert report.day2 == %{returned: counts(1, 0, 1), due: counts(1, 0, 1)}
  end

  test "the median of no timed turns is nil" do
    report = BetaReport.build(~D[2026-01-01], ~D[2026-01-02], @today)

    assert report.median_turn_ms == %{accounts: nil, guests: nil, all: nil}
    assert report.players == counts(0, 0, 0)
  end

  test "the Classic export carries only ids and first-played days of players who played" do
    assert BetaReport.classic_csv() ==
             "classic_user_id,first_played_on\n502,2026-10-05\n501,2026-10-10\n"
  end

  defp classic(user, classic_user_id) do
    user
    |> Ecto.Changeset.change(
      classic_user_id: classic_user_id,
      classic_claimed_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp finished(rule_set, completed_at, player_ids) do
    Repo.insert!(%GameStats{
      room_code: "ROOM",
      rule_set: rule_set,
      completed_at: completed_at,
      player_ids: player_ids
    })
  end

  defp archive(status, rule_set, started_at, seats) do
    participants =
      [:north, :east, :south, :west]
      |> Enum.zip(seats)
      |> Map.new(fn
        {position, :bot} -> {position, %{"occupant_type" => "bot", "user_id" => nil}}
        {position, id} -> {position, %{"occupant_type" => "human", "user_id" => id}}
      end)

    snapshot = %{"state" => %{"variant" => rule_set}}

    Repo.insert!(%Archive{
      game_instance_id: Ecto.UUID.generate(),
      room_code: "ROOM",
      format_version: 1,
      versions: %{},
      participants: participants,
      user_ids: Enum.reject(seats, &(&1 == :bot)),
      status: status,
      evidence_status: "continuous",
      failed_checkpoints: 0,
      missing_revision_count: 0,
      last_revision: 0,
      initial_snapshot: snapshot,
      last_snapshot: snapshot,
      started_at: DateTime.add(started_at, 0, :microsecond),
      saved_at: DateTime.add(started_at, 0, :microsecond)
    })
  end

  defp seat(user_id, kind, elapsed_ms, at) do
    Repo.insert!(%SeatEvent{
      user_id: user_id,
      room_code: "ROOM",
      kind: kind,
      elapsed_ms: elapsed_ms,
      inserted_at: at
    })
  end

  defp abandoned(user_id, at) do
    Repo.insert!(%AbandonmentEvent{
      user_id: user_id,
      room_code: "ROOM",
      position: "north",
      inserted_at: at
    })
  end
end

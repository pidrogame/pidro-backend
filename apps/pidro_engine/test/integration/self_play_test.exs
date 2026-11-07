defmodule Pidro.Integration.SelfPlayTest do
  @moduledoc """
  The rulebook bot's release gate: seeded self-play against the random bot
  that every bot seat used before.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pidro.Selfplay, as: SelfplayTask
  alias Pidro.Bot.SelfPlay

  @moduletag :integration

  for variant <- [:finnish, :louisiana] do
    test "#{variant}: mixed and four-rulebook self-play finish without illegal moves" do
      for opponent <- [SelfPlay.random_policy(), SelfPlay.rulebook_policy()] do
        summary =
          SelfPlay.run(
            games: 200,
            seed: 196,
            variant: unquote(variant),
            a: {:a, SelfPlay.rulebook_policy()},
            b: {:b, opponent}
          )

        assert summary.complete == 200, inspect(summary.failures)
        assert summary.illegal == 0
        assert summary.crashed == 0
        assert summary.stalled == 0
        assert summary.capped == 0
      end
    end
  end

  test "over 2000 games the rulebook team beats random, makes its bids, and every game finishes" do
    summary = SelfPlay.run(games: 2000, seed: 1)
    rulebook = summary.teams.rulebook

    assert summary.complete == 2000, "unfinished games: #{inspect(summary.failures)}"
    assert summary.illegal == 0
    assert summary.crashed == 0
    assert summary.stalled == 0
    assert summary.capped == 0

    assert rulebook.win_rate >= 0.90, SelfPlay.format(summary)
    assert rulebook.made_rate >= 0.70, SelfPlay.format(summary)
  end

  test "four rulebook seats make at least 70% of their bids against each other" do
    policy = SelfPlay.rulebook_policy()
    summary = SelfPlay.run(games: 2000, seed: 2, a: {:a, policy}, b: {:b, policy})

    assert summary.complete == 2000
    made = summary.teams.a.made + summary.teams.b.made
    contracts = summary.teams.a.contracts + summary.teams.b.contracts
    assert made / contracts >= 0.70, SelfPlay.format(summary)
  end

  test "the same seed gives the same summary" do
    first = SelfPlay.run(games: 40, seed: 5)
    second = SelfPlay.run(games: 40, seed: 5, max_concurrency: 1)

    assert Map.delete(first, :timing) == Map.delete(second, :timing)

    other = SelfPlay.run(games: 40, seed: 6)
    assert Map.drop(first, [:timing, :seed]) != Map.drop(other, [:timing, :seed])
  end

  test "auction metrics distinguish partner raises kept from those outbid by opponents" do
    for contest? <- [false, true] do
      play = SelfPlay.rulebook_policy()

      policy = fn
        %{phase: :bidding, bids: bids}, _legal ->
          case length(bids) do
            0 -> {:bid, 6}
            1 -> :pass
            2 -> {:bid, 7}
            3 -> if contest?, do: {:bid, 8}, else: :pass
          end

        view, legal ->
          play.(view, legal)
      end

      summary = SelfPlay.run(games: 20, seed: 271, a: {:a, policy}, b: {:b, policy})
      assert summary.complete == 20
      total = fn key -> summary.teams.a[key] + summary.teams.b[key] end
      assert summary.forced_sixes == 0
      assert summary.volunteered == summary.hands
      assert summary.auctions == summary.hands
      assert total.(:volunteered_sixes) == 0
      assert total.(:cheap_opportunities) == summary.hands * 2
      assert total.(:cheap_contests) == if(contest?, do: summary.hands, else: 0)
      assert total.(:partner_opportunities) == summary.hands
      assert total.(:partner_raises) == summary.hands
      assert total.(:partner_raise_contracts) == if(contest?, do: 0, else: summary.hands)
      assert total.(:partner_raises_made) == if(contest?, do: 0, else: total.(:made))
      assert summary.teams.a.average_bid == if(contest?, do: 8.0, else: 7.0)
      assert total.(:set_points) == total.(:set) * if(contest?, do: 8, else: 7)
      assert summary.teams.b.average_bid == if(contest?, do: 8.0, else: 7.0)
    end
  end

  test "a dealer's forced 6 is not volunteered; a first seat's 6 with no reply is not an auction" do
    for open? <- [false, true] do
      play = SelfPlay.rulebook_policy()

      policy = fn
        %{phase: :bidding, bids: bids}, legal ->
          if :pass not in legal or (open? and bids == []), do: {:bid, 6}, else: :pass

        view, legal ->
          play.(view, legal)
      end

      summary = SelfPlay.run(games: 20, seed: 377, a: {:a, policy}, b: {:b, policy})
      assert summary.complete == 20
      total = fn key -> summary.teams.a[key] + summary.teams.b[key] end
      assert summary.forced_sixes == if(open?, do: 0, else: summary.hands)
      assert summary.volunteered == if(open?, do: summary.hands, else: 0)
      assert summary.auctions == 0
      assert total.(:volunteered_sixes) == summary.volunteered
      assert total.(:volunteered_sixes_made) == if(open?, do: total.(:made), else: 0)
    end
  end

  test "a policy that plays illegal moves fails every game at once instead of looping" do
    illegal = fn _view, _legal -> {:bid, 99} end
    summary = SelfPlay.run(games: 6, seed: 1, a: {:bad, illegal})

    assert summary.illegal == 6
    assert summary.complete == 0
    assert [{:illegal_action, _position, {:bid, 99}} | _] = summary.failures
  end

  test "a policy that raises is reported as a crash" do
    raising = fn _view, _legal -> raise "boom" end
    summary = SelfPlay.run(games: 2, seed: 1, b: {:raising, raising})

    assert summary.crashed == 2
    assert [{:crash, "boom"} | _] = summary.failures
  end

  test "the action cap ends a game that runs too long" do
    summary = SelfPlay.run(games: 2, seed: 1, max_actions: 10)
    assert summary.capped == 2
  end

  test "the mix task prints the summary for a game count and seed" do
    output = capture_io(fn -> SelfplayTask.run(["--games", "20", "--seed", "3"]) end)

    assert output =~ "Self-play: 20 games, seed 3"
    assert output =~ "rulebook"
    assert output =~ "random"
    assert output =~ "complete 20, illegal 0"
  end
end

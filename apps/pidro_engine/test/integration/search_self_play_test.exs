defmodule Pidro.Integration.SearchSelfPlayTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.SelfPlay

  @moduletag :integration

  test "search plays whole games against the rulebook without an illegal move and reports what it overruled" do
    {:ok, critic} = Agent.start_link(fn -> [] end)
    search = SelfPlay.search_policy(worlds: 6, veto: 0.4, seed: 9, critic: critic)

    summary =
      SelfPlay.run(
        pairs: 2,
        seed: 379,
        a: {:search, search},
        b: {:rulebook, SelfPlay.rulebook_policy()}
      )

    assert summary.complete == 4, inspect(summary.failures)
    assert summary.illegal == 0
    assert summary.crashed == 0
    assert summary.timing.search.p50 > summary.timing.rulebook.p50

    overruled = Agent.get(critic, & &1)
    assert overruled != []

    for record <- overruled do
      assert record.search != record.rulebook
      assert %{phase: phase} = record.shape
      assert phase in [:bidding, :playing]
    end
  end
end

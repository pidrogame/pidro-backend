defmodule Mix.Tasks.Pidro.Selfplay do
  @moduledoc """
  Plays seeded games between two bot teams and prints how each team did.

      mix pidro.selfplay                          # 2000 games, seed 1, rulebook vs random
      mix pidro.selfplay --games 500 --seed 7
      mix pidro.selfplay --a rulebook --b rulebook
      mix pidro.selfplay --pairs 1000 --seed 71 --a rulebook --b random

  Team A alternates between North/South and East/West. The summary reports
  win rate, bids made and set, points lost to sets, average winning bid,
  decision times, and any illegal move, crash, stall or capped game. The task
  exits non-zero if a game did not finish cleanly. Needs no database.
  """
  use Mix.Task

  alias Pidro.Bot.SelfPlay

  @shortdoc "Plays seeded bot-vs-bot games and prints a summary"

  @policies ~w(rulebook random regular)

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [games: :integer, pairs: :integer, seed: :integer, a: :string, b: :string]
      )

    if invalid != [], do: usage("Unknown options: #{inspect(invalid)}")
    if rest != [], do: usage("Unexpected arguments: #{inspect(rest)}")

    if Keyword.has_key?(opts, :pairs) and Keyword.has_key?(opts, :games),
      do: usage("Choose --pairs or --games, not both")

    count_key = if Keyword.has_key?(opts, :pairs), do: :pairs, else: :games
    count = Keyword.get(opts, count_key, 2000)
    if count < 1, do: usage("Game/pair count must be positive")

    a = Keyword.get(opts, :a, "rulebook")
    b = Keyword.get(opts, :b, "random")
    policy_a = policy(a)
    policy_b = policy(b)
    {label_a, label_b} = if a == b, do: {"#{a}_a", "#{b}_b"}, else: {a, b}

    summary =
      SelfPlay.run(
        [{count_key, count}] ++
          [
            seed: Keyword.get(opts, :seed, 1),
            a: {String.to_atom(label_a), policy_a},
            b: {String.to_atom(label_b), policy_b}
          ]
      )

    Mix.shell().info(SelfPlay.format(summary))

    if summary.complete != summary.games do
      Mix.shell().error("Games that did not finish: #{inspect(summary.failures)}")
      exit({:shutdown, 1})
    end
  end

  defp policy("rulebook"), do: SelfPlay.rulebook_policy()
  defp policy("random"), do: SelfPlay.random_policy()
  defp policy("regular"), do: SelfPlay.rulebook_policy()

  defp policy(name),
    do: usage("Unknown policy #{inspect(name)}; use one of #{Enum.join(@policies, ", ")}")

  defp usage(message) do
    Mix.shell().error(message)

    Mix.shell().info(
      "Usage: mix pidro.selfplay [--games N | --pairs N] [--seed N] [--a POLICY] [--b POLICY]\nPolicies: #{Enum.join(@policies, ", ")}"
    )

    exit({:shutdown, 1})
  end
end

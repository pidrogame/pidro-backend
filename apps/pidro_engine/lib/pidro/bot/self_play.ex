defmodule Pidro.Bot.SelfPlay do
  @moduledoc """
  Plays whole games between two bot teams through the engine and reports
  how each team did.

  A policy is a function from a seat view and the legal actions to an
  action. The harness builds the view for the seat to move, so every policy
  it runs is held to the same fairness rule as a seated bot.

  Games are seeded and each runs in its own process, so a run with the same
  seed gives the same summary. Team A sits North/South in even-numbered
  games and East/West in odd ones. A game ends in one of:

  - `:complete` - a team reached the winning score
  - `{:illegal_action, position, action}` - a policy chose a move that was not legal
  - `{:crash, message}` - a policy raised or the engine rejected a legal move
  - `:stalled` - the seat to move had no legal action
  - `:capped` - the game passed the action cap

  Only complete games count towards win rates. Anything else is a failure the
  release gate refuses.
  """

  alias Pidro.Bot.{Knowledge, RandomPolicy, Rulebook, Search}
  alias Pidro.Core.{GameState, SeatView, Types}
  alias Pidro.Game.{DealerRob, Dealing, Engine}

  @type policy :: (SeatView.t(), [Types.action(), ...] -> Types.action())
  @type team_spec :: {atom(), policy()}
  @type outcome ::
          :complete
          | :capped
          | :stalled
          | {:illegal_action, Types.position(), term()}
          | {:crash, String.t()}

  @type hand_record :: %{
          team: Types.team(),
          bid: Types.bid_amount(),
          bids_made: pos_integer(),
          forced?: boolean(),
          made?: boolean(),
          partner_raise?: boolean(),
          bidding: [map()]
        }

  @type game_result :: %{
          outcome: outcome(),
          winner: Types.team() | nil,
          actions: non_neg_integer(),
          hands: [hand_record()],
          fives: [%{owner: Types.team(), winner: Types.team()}],
          decision_us: %{Types.team() => [non_neg_integer()]}
        }

  @default_max_actions 5_000

  @doc """
  Returns the production rulebook as an evaluation policy.
  """
  @spec rulebook_policy() :: policy()
  def rulebook_policy do
    fn view, legal ->
      {action, _reason} = Rulebook.decide(view, legal)
      action
    end
  end

  @doc """
  Returns the research search bot (`Pidro.Bot.Search`) as a policy.

  Takes `Pidro.Bot.Search` options (`:worlds`, `:veto`, `:threshold`,
  `:seed`) and `:critic`, an `Agent` that collects every position where
  search overruled the rulebook (`Pidro.Bot.Search.disagreement/2`).
  """
  @spec search_policy(keyword()) :: policy()
  def search_policy(opts \\ []) do
    {critic, opts} = Keyword.pop(opts, :critic)

    fn view, legal ->
      analysis = Search.analyse(view, legal, opts)

      if critic && analysis.choice != analysis.rulebook do
        record = Search.disagreement(view, analysis)
        Agent.update(critic, &[record | &1])
      end

      analysis.choice
    end
  end

  @doc """
  Returns the random baseline as a policy.
  """
  @spec random_policy() :: policy()
  def random_policy, do: &RandomPolicy.choose/2

  @doc """
  Plays one game.

  ## Parameters

  - `policies` - `%{north_south: policy, east_west: policy}`
  - `opts`
    - `:seed` - integer seed for the deal and any random policy (default 0)
    - `:variant` - game rules (default `:finnish`)
    - `:max_actions` - action cap (default #{@default_max_actions})

  ## Returns

  A `game_result` map. `decision_us` holds, per team, the microseconds each
  decision took, including building the seat view.
  """
  @spec play_game(%{Types.team() => policy()}, keyword()) :: game_result()
  def play_game(policies, opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)
    max_actions = Keyword.get(opts, :max_actions, @default_max_actions)
    # Seeds the *policy* RNG only: `RandomPolicy` draws from the process
    # dictionary, and it does so outside `apply_action/3`. The engine takes its
    # randomness from `GameState.new(seed: ...)` below and nothing it does
    # depends on this line.
    :rand.seed(:exsss, {seed, 0x5EED, 0xB07})

    variant = Keyword.get(opts, :variant, :finnish)
    {:ok, cut} = Dealing.select_dealer(GameState.new(seed: seed, variant: variant))
    {:ok, state} = Engine.advance_from_dealer_selection(cut)

    acc = %{actions: 0, decision_us: %{north_south: [], east_west: []}}
    {outcome, final, acc} = loop(state, policies, max_actions, acc)

    %{
      outcome: outcome,
      winner: if(outcome == :complete, do: final.winner),
      actions: acc.actions,
      hands: hand_records(final.events),
      fives: five_records(final.events),
      decision_us: acc.decision_us
    }
  end

  @doc """
  Plays a series of games between team A and team B and summarises them.

  ## Options

  - `:games` - number of unpaired games (default 100)
  - `:pairs` - play each seed twice with teams swapped; mutually exclusive with `:games`
  - `:seed` - base seed (default 1); game `i` uses seed `seed * 100_000 + i`
  - `:variant` - game rules (default `:finnish`)
  - `:a`, `:b` - `{label, policy}` for each team (default rulebook vs random)
  - `:max_actions` - per-game action cap
  - `:max_concurrency` - games played at once (default: online schedulers)

  ## Returns

  A summary map with, per label, games won, win rate, contracts won, bids
  made and set, points lost to sets, made rate (also without forced dealer
  bids), and average winning bid; plus counts of illegal moves, crashes,
  stalls and capped games, and per-label decision times under `:timing`. Five metrics count cards, not
  points: captured includes own Fives kept, taken means an opposing Five
  captured, and lost means an own Five captured by the opponents. Only
  completed tricks count, including completed tricks in failed games.

  Auction metrics use scored hands only. Opportunities count turns facing
  an opponent's standing 6 or 7, or a partner's standing bid. Raises count
  bids on those turns, even if later outbid. A partner raise's made rate
  counts only raises that won the contract, not those later outbid. The
  forced-dealer-6 share uses all scored hands as its denominator, as do
  volunteered contracts (any contract but a forced dealer bid) and auctions
  (hands with two or more bids). The volunteered-6 made rate counts
  unforced contracts of exactly 6.

  Paired runs also include each pair's seed and winners, sweep/split counts
  and incomplete pairs. Pairing fixes cuts and deck order per hand; different
  trump choices and game lengths can still yield different hands. It does
  not promise identical random-policy choices after play diverges.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    if Keyword.has_key?(opts, :pairs) and Keyword.has_key?(opts, :games),
      do: raise(ArgumentError, "choose either :pairs or :games")

    paired? = Keyword.has_key?(opts, :pairs)
    count = positive!(Keyword.get(opts, if(paired?, do: :pairs, else: :games), 100))
    games = if paired?, do: count * 2, else: count
    seed = Keyword.get(opts, :seed, 1)
    {label_a, policy_a} = Keyword.get(opts, :a, {:rulebook, rulebook_policy()})
    {label_b, policy_b} = Keyword.get(opts, :b, {:random, random_policy()})
    if label_a == label_b, do: raise(ArgumentError, "team labels must differ")
    concurrency = positive!(Keyword.get(opts, :max_concurrency, System.schedulers_online()))
    game_opts = Keyword.take(opts, [:max_actions, :variant])

    jobs =
      for i <- 1..count,
          team <- if(paired?, do: [:north_south, :east_west], else: [alternating_team(i)]),
          do: {seed * 100_000 + i, team}

    results =
      jobs
      |> Task.async_stream(
        fn {game_seed, a_team} ->
          b_team = Types.opposing_team(a_team)
          policies = %{a_team => policy_a, b_team => policy_b}
          result = play_game(policies, [seed: game_seed] ++ game_opts)
          {%{a_team => label_a, b_team => label_b}, result}
        end,
        ordered: true,
        timeout: :infinity,
        max_concurrency: concurrency
      )
      |> Enum.map(fn {:ok, labelled} -> labelled end)

    summary = summarise(results, [label_a, label_b], games, seed)

    if paired? do
      Map.merge(summary, %{
        pairs: count,
        pair_results: summarise_pairs(results, seed, [label_a, label_b])
      })
    else
      summary
    end
  end

  defp positive!(n) when is_integer(n) and n > 0, do: n

  defp positive!(_),
    do: raise(ArgumentError, "game/pair counts and concurrency must be positive integers")

  defp alternating_team(i), do: if(rem(i, 2) == 0, do: :north_south, else: :east_west)

  @doc """
  Formats a summary from `run/1` as text for the terminal.
  """
  @spec format(map()) :: String.t()
  def format(summary) do
    teams =
      for label <- summary.labels do
        t = summary.teams[label]
        time = summary.timing[label]

        """
        #{label}
          wins            #{t.wins}/#{summary.complete} (#{pct(t.win_rate)})
          contracts       #{t.contracts} (#{t.forced} forced), average winning bid #{Float.round(t.average_bid, 2)}
          made / set      #{t.made} / #{t.set} (#{pct(t.made_rate)}; #{pct(t.made_rate_unforced)} unforced), #{t.set_points} points lost to sets
          volunteered 6s  #{t.volunteered_sixes_made}/#{t.volunteered_sixes} made (#{pct(t.volunteered_six_made_rate)})
          cheap contests  #{t.cheap_contests}/#{t.cheap_opportunities} (#{pct(t.cheap_contest_rate)})
          partner raises  #{t.partner_raises}/#{t.partner_opportunities} (#{pct(t.partner_raise_rate)}); won #{t.partner_raise_contracts}, made #{t.partner_raises_made} (#{pct(t.partner_raise_made_rate)})
          Fives           #{t.fives_captured} captured, #{t.fives_taken} taken from opponents, #{t.fives_lost} lost
          decision time   p50 #{time.p50} µs, p95 #{time.p95} µs, max #{time.max} µs
        """
      end

    """
    Self-play: #{summary.games} games, seed #{summary.seed}
    Scored hands: #{summary.hands}; forced dealer 6: #{summary.forced_sixes} (#{pct(ratio(summary.forced_sixes, summary.hands))}); volunteered contracts #{Float.round(ratio(summary.volunteered, summary.hands), 3)} per hand; two or more bids: #{summary.auctions} (#{pct(ratio(summary.auctions, summary.hands))})
    #{format_pairs(summary)}#{Enum.join(teams)}
    complete #{summary.complete}, illegal #{summary.illegal}, crashed #{summary.crashed}, stalled #{summary.stalled}, capped #{summary.capped}
    """
  end

  defp format_pairs(%{pairs: pairs, pair_results: result}) do
    "Pairs: #{pairs}, complete #{result.complete}, splits #{result.splits}, " <>
      "sweeps #{inspect(result.sweeps)}, failed #{result.failed}\n"
  end

  defp format_pairs(_), do: ""

  # --- Game loop --------------------------------------------------------------

  defp loop(%{phase: :complete} = state, _policies, _max, acc), do: {:complete, state, acc}
  defp loop(state, _policies, max, %{actions: n} = acc) when n >= max, do: {:capped, state, acc}

  defp loop(state, policies, max, acc) do
    position = state.current_turn

    case position && Engine.legal_actions(state, position) do
      [_ | _] = legal ->
        team = Types.position_to_team(position)

        case decide(policies[team], state, position, legal) do
          {:ok, action, micros} ->
            acc = %{acc | decision_us: Map.update!(acc.decision_us, team, &[micros | &1])}
            step(state, position, action, legal, policies, max, acc)

          {:error, message} ->
            {{:crash, message}, state, acc}
        end

      _none ->
        {:stalled, state, acc}
    end
  end

  defp decide(policy, state, position, legal) do
    {micros, action} = :timer.tc(fn -> policy.(SeatView.for_seat(state, position), legal) end)
    {:ok, action, micros}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp step(state, position, action, legal, policies, max, acc) do
    if action in legal do
      case Engine.apply_action(state, position, resolve(action, state, position)) do
        {:ok, next} ->
          loop(next, policies, max, %{acc | actions: acc.actions + 1})

        {:error, reason} ->
          {{:crash, "engine rejected #{inspect(action)}: #{inspect(reason)}"}, state, acc}
      end
    else
      {{:illegal_action, position, action}, state, acc}
    end
  end

  # The dealer's rob stays with the engine's own selection, as on the server.
  defp resolve({:select_hand, :choose_6_cards}, state, position) do
    pool = state.players[position].hand ++ state.deck
    {:select_hand, DealerRob.select_best_cards(pool, state.trump_suit)}
  end

  defp resolve(action, _state, _position), do: action

  # --- Results ----------------------------------------------------------------

  # One record per scored hand, read from the engine's events: the contract
  # from `:bidding_complete`, whether the dealer was forced from the bids
  # before it, and the outcome from the bidding team's `:hand_scored` delta.
  defp hand_records(events) do
    empty = %{bids: [], contract: nil, standing: nil, bidding: [], partner_raise?: false}

    {records, _hand} =
      Enum.reduce(events, {[], empty}, fn
        {:cards_dealt, _}, {records, _hand} ->
          {records, empty}

        {:player_passed, pos}, {records, hand} ->
          hand = bidding_opportunity(hand, pos, false)
          {records, %{hand | bids: [:pass | hand.bids]}}

        {:bid_made, pos, amount}, {records, hand} ->
          partner = Types.partner_position(pos)
          partner_raise? = match?({^partner, _}, hand.standing)
          hand = bidding_opportunity(hand, pos, true)

          {records,
           %{
             hand
             | bids: [amount | hand.bids],
               standing: {pos, amount},
               partner_raise?: partner_raise?
           }}

        {:bidding_complete, pos, amount}, {records, hand} ->
          forced? = hand.bids == [amount, :pass, :pass, :pass]

          contract = %{
            team: Types.position_to_team(pos),
            bid: amount,
            bids_made: Enum.count(hand.bids, &is_integer/1),
            forced?: forced?,
            partner_raise?: hand.partner_raise?,
            bidding: hand.bidding
          }

          {records, %{hand | contract: contract}}

        {:hand_scored, team, delta}, {records, %{contract: %{team: team} = contract} = hand} ->
          {[Map.put(contract, :made?, delta >= 0) | records], %{hand | contract: nil}}

        _event, acc ->
          acc
      end)

    Enum.reverse(records)
  end

  defp bidding_opportunity(%{standing: nil} = hand, _pos, _raised?), do: hand

  defp bidding_opportunity(%{standing: {bidder, amount}} = hand, pos, raised?) do
    kind =
      cond do
        bidder == Types.partner_position(pos) -> :partner
        amount in [6, 7] -> :cheap
        true -> :other
      end

    decision = %{team: Types.position_to_team(pos), kind: kind, raised?: raised?}
    %{hand | bidding: [decision | hand.bidding]}
  end

  # Read public events rather than hidden hands. A Five is lost only when a
  # completed trick awards it to the other team; this is not a mistake label.
  defp five_records(events) do
    {records, _trump, _owners} =
      Enum.reduce(events, {[], nil, []}, fn
        {:trump_declared, suit}, {records, _, _} ->
          {records, suit, []}

        {:card_played, position, card}, {records, trump, owners} ->
          owners =
            if Knowledge.five?(card, trump),
              do: [Types.position_to_team(position) | owners],
              else: owners

          {records, trump, owners}

        {:trick_won, position, _points}, {records, trump, owners} ->
          won = for owner <- owners, do: %{owner: owner, winner: Types.position_to_team(position)}
          {won ++ records, trump, []}

        _, acc ->
          acc
      end)

    Enum.reverse(records)
  end

  defp summarise_pairs(results, seed, labels) do
    pairs =
      results
      |> Enum.chunk_every(2)
      |> Enum.with_index(1)
      |> Enum.map(fn {pair, i} ->
        %{
          seed: seed * 100_000 + i,
          winners: Enum.map(pair, fn {teams, game} -> teams[game.winner] end),
          complete?: Enum.all?(pair, fn {_, game} -> game.outcome == :complete end)
        }
      end)

    complete = Enum.filter(pairs, & &1.complete?)

    %{
      results: pairs,
      complete: length(complete),
      failed: length(pairs) - length(complete),
      splits: Enum.count(complete, fn %{winners: [a, b]} -> a != b end),
      sweeps:
        Map.new(labels, fn label ->
          {label, Enum.count(complete, &(&1.winners == [label, label]))}
        end)
    }
  end

  defp summarise(results, labels, games, seed) do
    complete = for {teams, %{outcome: :complete} = r} <- results, do: {teams, r}
    all_hands = for {_, r} <- results, hand <- r.hands, do: hand

    fives =
      for {teams, r} <- results, five <- r.fives, do: {teams[five.owner], teams[five.winner]}

    team_stats =
      Map.new(labels, fn label ->
        hands =
          for {teams, r} <- results, hand <- r.hands, teams[hand.team] == label, do: hand

        wins = Enum.count(complete, fn {teams, r} -> teams[r.winner] == label end)
        unforced = Enum.reject(hands, & &1.forced?)
        raises = Enum.filter(hands, & &1.partner_raise?)
        volunteered_sixes = Enum.filter(unforced, &(&1.bid == 6))
        volunteered_sixes_made = Enum.count(volunteered_sixes, & &1.made?)
        raised_made = Enum.count(raises, & &1.made?)

        decisions =
          for {teams, r} <- results,
              hand <- r.hands,
              decision <- hand.bidding,
              teams[decision.team] == label,
              do: decision

        cheap = Enum.filter(decisions, &(&1.kind == :cheap))
        partners = Enum.filter(decisions, &(&1.kind == :partner))
        contested = Enum.count(cheap, & &1.raised?)
        raised = Enum.count(partners, & &1.raised?)

        {label,
         %{
           cheap_opportunities: length(cheap),
           cheap_contests: contested,
           cheap_contest_rate: ratio(contested, length(cheap)),
           partner_opportunities: length(partners),
           partner_raises: raised,
           partner_raise_rate: ratio(raised, length(partners)),
           partner_raise_contracts: length(raises),
           partner_raises_made: raised_made,
           partner_raise_made_rate: ratio(raised_made, length(raises)),
           fives_captured: Enum.count(fives, fn {_, winner} -> winner == label end),
           fives_taken:
             Enum.count(fives, fn {owner, winner} -> winner == label and owner != label end),
           fives_lost:
             Enum.count(fives, fn {owner, winner} -> owner == label and winner != label end),
           wins: wins,
           win_rate: ratio(wins, length(complete)),
           contracts: length(hands),
           forced: length(hands) - length(unforced),
           made: Enum.count(hands, & &1.made?),
           set: Enum.count(hands, &(not &1.made?)),
           set_points: hands |> Enum.reject(& &1.made?) |> Enum.map(& &1.bid) |> Enum.sum(),
           made_rate: ratio(Enum.count(hands, & &1.made?), length(hands)),
           made_rate_unforced: ratio(Enum.count(unforced, & &1.made?), length(unforced)),
           volunteered_sixes: length(volunteered_sixes),
           volunteered_sixes_made: volunteered_sixes_made,
           volunteered_six_made_rate: ratio(volunteered_sixes_made, length(volunteered_sixes)),
           average_bid: ratio(Enum.sum(Enum.map(hands, & &1.bid)), length(hands))
         }}
      end)

    timing =
      Map.new(labels, fn label ->
        times =
          for({teams, r} <- results, {team, us} <- r.decision_us, teams[team] == label, do: us)
          |> List.flatten()
          |> Enum.sort()

        {label, percentiles(times)}
      end)

    %{
      games: games,
      seed: seed,
      labels: labels,
      hands: length(all_hands),
      forced_sixes: Enum.count(all_hands, &(&1.forced? and &1.bid == 6)),
      volunteered: Enum.count(all_hands, &(not &1.forced?)),
      auctions: Enum.count(all_hands, &(&1.bids_made >= 2)),
      complete: length(complete),
      teams: team_stats,
      illegal: Enum.count(results, &match?({_, %{outcome: {:illegal_action, _, _}}}, &1)),
      crashed: Enum.count(results, &match?({_, %{outcome: {:crash, _}}}, &1)),
      stalled: Enum.count(results, &match?({_, %{outcome: :stalled}}, &1)),
      capped: Enum.count(results, &match?({_, %{outcome: :capped}}, &1)),
      failures:
        for({_, %{outcome: outcome}} <- results, outcome != :complete, do: outcome)
        |> Enum.take(5),
      timing: timing
    }
  end

  defp percentiles([]), do: %{p50: 0, p95: 0, max: 0}

  defp percentiles(sorted) do
    at = fn q -> Enum.at(sorted, min(length(sorted) - 1, trunc(q * length(sorted)))) end
    %{p50: at.(0.5), p95: at.(0.95), max: List.last(sorted)}
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp pct(rate), do: "#{Float.round(rate * 100, 1)}%"
end

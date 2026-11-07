defmodule Pidro.Bot.Search do
  @moduledoc """
  A search bot on top of the rulebook: it deals out the cards it cannot see,
  plays each candidate out in every dealt world, and keeps the move that
  scores best on average (determinized search, as in GIB's PIMC).

  Research only: no table plays it. `Pidro.Bot.SelfPlay.search_policy/1`
  runs it in the harness, and `mix pidro.selfplay --a search` measures it.

  It decides from a `SeatView` only. Worlds come from
  `Pidro.Bot.Search.Determinizer`, seeded from the `:seed` option and the
  position, so a seed reproduces every decision. Each world is played out by
  `Pidro.Bot.Search.Rollout` with the rulebook in every seat, and all
  candidates are played in the same worlds.

  - **Play.** With more than one legal card, each card is worth the average
    hand value of its rollouts. The rulebook's card stands unless another
    beats it by at least `:veto` hand points, so most moves stay ones the
    rulebook can explain.
  - **Bidding.** The bid stays the rulebook's (PID-365: the minimum that
    takes the contract, or one more to shut out), or the minimum when the
    rulebook passes; search only decides whether to take it. It bids when
    the side holding the contract makes it in at least `:threshold` of the
    worlds where it holds it. A forced dealer and a seat over its partner's
    bid keep the rulebook's move.
  - Every other decision, every Louisiana decision, and any failure, is the
    rulebook's.

  Options: `:worlds` (default 100), `:veto` (0.4), `:threshold` (0.7),
  `:seed` (0).
  """

  alias Pidro.Bot.{Bidding, Knowledge, Rulebook}
  alias Pidro.Bot.Search.{Determinizer, Rollout}
  alias Pidro.Core.{Card, SeatView, Types}

  @type analysis :: %{
          rulebook: Types.action(),
          choice: Types.action(),
          reason: String.t(),
          values: %{Types.action() => float()}
        }

  @defaults [worlds: 100, veto: 0.4, threshold: 0.7, seed: 0]

  @doc """
  Chooses a move for the seat in `view` from `legal`.

  ## Returns

  `{action, reason}`, where `action` is a member of `legal`.
  """
  @spec decide(SeatView.t(), [Types.action(), ...], keyword()) :: {Types.action(), String.t()}
  def decide(%SeatView{} = view, [_ | _] = legal, opts \\ []) do
    %{choice: choice, reason: reason} = analyse(view, legal, opts)
    {choice, reason}
  end

  @doc """
  Like `decide/3`, but also returns the rulebook's move and each searched
  candidate's value (empty when search did not run).
  """
  @spec analyse(SeatView.t(), [Types.action(), ...], keyword()) :: analysis()
  def analyse(%SeatView{} = view, [_ | _] = legal, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    {rulebook, reason} = Rulebook.decide(view, legal)
    base = %{rulebook: rulebook, choice: rulebook, reason: reason, values: %{}}

    try do
      search(view, legal, base, opts)
    rescue
      _error -> base
    end
  end

  @doc """
  The readability veto: keeps the rulebook's move unless the best value
  beats it by more than zero and by at least `margin` hand points.

  ## Examples

      iex> Pidro.Bot.Search.pick(%{{:play_card, {6, :hearts}} => 1.0, {:play_card, {14, :hearts}} => 1.9}, {:play_card, {6, :hearts}}, 0.4)
      {{:play_card, {14, :hearts}}, "Rulebook says 6♥; search prefers A♥ by 0.9 points, so A♥."}
  """
  @spec pick(%{Types.action() => number()}, Types.action(), number()) ::
          {Types.action(), String.t()}
  def pick(values, rulebook, margin) do
    {best, top} = Enum.max_by(values, &elem(&1, 1))
    gain = top - values[rulebook]
    says = "Rulebook says #{label(rulebook)}"
    by = Float.round(gain * 1.0, 1)

    cond do
      gain <= 0 ->
        {rulebook, "#{says}; search agrees."}

      gain >= margin ->
        {best, "#{says}; search prefers #{label(best)} by #{by} points, so #{label(best)}."}

      true ->
        {rulebook,
         "#{says}; search prefers #{label(best)} by only #{by} points, so #{label(rulebook)}."}
    end
  end

  @doc """
  A short name for an action: `"A♥"`, `"bid 7"`, `"pass"`.
  """
  @spec label(Types.action()) :: String.t()
  def label({:play_card, {rank, suit}}), do: rank_label(rank) <> suit_symbol(suit)
  def label({:bid, amount}), do: "bid #{amount}"
  def label(:pass), do: "pass"
  def label(action), do: inspect(action)

  @doc """
  Records a position where search overruled the rulebook, for the critic
  report: its shape, both moves, the values, and the position in words.

  The shape is what a rule could key on: phase, trick number, who is winning
  the trick (in the auction, who holds the standing bid), points on the
  trick (the standing bid), trumps in hand (in the auction, cards in the
  best suit), whether a Five is involved, and both moves.
  """
  @spec disagreement(SeatView.t(), analysis()) :: map()
  def disagreement(%SeatView{} = view, %{rulebook: rulebook, choice: choice} = analysis) do
    %{
      shape: shape(view, rulebook, choice),
      rulebook: rulebook,
      search: choice,
      values: analysis.values,
      reason: analysis.reason,
      example: describe(view)
    }
  end

  @doc """
  Formats the `top` most frequent disagreement shapes as Markdown, each with
  its count, both moves, and as its example the position where search
  preferred its move by the widest margin.
  """
  @spec report([map()], pos_integer()) :: String.t()
  def report(records, top \\ 20) do
    records
    |> Enum.group_by(& &1.shape)
    |> Enum.sort_by(fn {shape, group} -> {-length(group), inspect(shape)} end)
    |> Enum.take(top)
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{shape, group}, i} ->
      example = Enum.max_by(group, &{&1.values[&1.search] - &1.values[&1.rulebook], &1.example})

      """
      ### #{i}. #{shape_title(shape)} (#{length(group)} times)

      #{example.example}

      #{example.reason}
      """
    end)
  end

  defp shape(%SeatView{phase: :bidding} = view, rulebook, choice) do
    dealer? = view.current_dealer == view.position
    {suit, _estimate} = Bidding.best_suit(view.hand, dealer?, view.variant)
    trumps = Enum.filter(view.hand, &Card.is_trump?(&1, suit))

    %{
      phase: :bidding,
      trick: 0,
      winning: holder(view, view.highest_bid && elem(view.highest_bid, 0)),
      points: if(view.highest_bid, do: elem(view.highest_bid, 1), else: 0),
      trumps: length(trumps),
      five: Enum.any?(trumps, &Knowledge.five?(&1, suit)),
      moves: {label(rulebook), label(choice)}
    }
  end

  defp shape(%SeatView{trump_suit: trump} = view, rulebook, choice) do
    on_trick = for {_pos, card} <- trick_plays(view), do: card

    %{
      phase: :playing,
      trick: length(view.tricks) + 1,
      winning: holder(view, with({pos, _card} <- Knowledge.current_winner(view), do: pos)),
      points: Knowledge.points_on_trick(view),
      trumps: length(Knowledge.my_trumps(view)),
      five: Enum.any?(view.hand ++ on_trick, &Knowledge.five?(&1, trump)),
      moves: {relative(rulebook, trump), relative(choice, trump)}
    }
  end

  defp holder(_view, nil), do: :nobody

  defp holder(view, pos),
    do: if(Types.position_to_team(pos) == Knowledge.my_team(view), do: :us, else: :them)

  defp relative({:play_card, {5, suit}}, trump) when suit != trump, do: "off-5"
  defp relative({:play_card, {rank, _suit}}, _trump), do: rank_label(rank)

  defp shape_title(%{phase: :bidding} = s) do
    standing =
      case s.winning do
        :nobody -> "no bid yet"
        :us -> "partner's #{s.points} stands"
        :them -> "opponents' #{s.points} stands"
      end

    five = if s.five, do: " with a Five", else: ""
    {rule, search} = s.moves

    "Auction, #{standing}, #{s.trumps} cards in the best suit#{five}: " <>
      "rulebook #{rule}, search #{search}"
  end

  defp shape_title(s) do
    winning = %{nobody: "leading", us: "partner winning", them: "opponents winning"}[s.winning]
    five = if s.five, do: ", a Five involved", else: ""
    {rule, search} = s.moves

    "Trick #{s.trick}, #{winning}, #{s.points} points on the trick, " <>
      "#{s.trumps} trumps in hand#{five}: rulebook #{rule}, search #{search}"
  end

  defp describe(%SeatView{phase: :bidding} = view) do
    "#{seat(view.position)} to bid, #{seat(view.current_dealer)} deals, #{scores(view)}. " <>
      "Bids: #{bids(view)}. Hand: #{cards(view.hand)}."
  end

  defp describe(%SeatView{} = view) do
    tricks = Enum.map_join(view.tricks, "; ", &"#{&1.number}: #{plays(&1.plays)}")
    current = if trick_plays(view) == [], do: "nothing yet", else: plays(trick_plays(view))

    held =
      for pos <- Types.all_positions(), pos != view.position do
        p = view.players[pos]
        "#{seat(pos)} #{if p.eliminated?, do: "cold", else: p.hand_count}"
      end

    drawn =
      Enum.map_join(Enum.sort(view.cards_requested), ", ", fn {p, n} -> "#{seat(p)} #{n}" end)

    {bidder, amount} = view.highest_bid

    "#{seat(view.position)} to play, #{seat(view.current_dealer)} dealt, " <>
      "#{seat(bidder)} bid #{amount}, trump #{suit_symbol(view.trump_suit)}, #{scores(view)}. " <>
      "Tricks: #{if tricks == "", do: "none", else: tricks}. This trick: #{current}. " <>
      "Hand: #{cards(view.hand)}. Cards held: #{Enum.join(held, ", ")}. Drawn: #{drawn}."
  end

  defp scores(view) do
    us = Knowledge.my_team(view)

    "score us #{view.cumulative_scores[us]}, them #{view.cumulative_scores[Types.opposing_team(us)]}"
  end

  defp bids(%SeatView{bids: []}), do: "none"

  defp bids(view) do
    Enum.map_join(view.bids, ", ", fn bid ->
      "#{seat(bid.position)} #{if bid.amount == :pass, do: "pass", else: bid.amount}"
    end)
  end

  defp plays(plays),
    do:
      Enum.map_join(plays, " ", fn {pos, card} -> "#{seat(pos)} #{label({:play_card, card})}" end)

  defp cards(cards), do: Enum.map_join(cards, " ", &label({:play_card, &1}))

  defp seat(pos), do: Types.position_to_string(pos)

  defp trick_plays(%SeatView{current_trick: %{plays: plays}}), do: plays
  defp trick_plays(%SeatView{}), do: []

  defp search(
         %SeatView{variant: :finnish, phase: :playing} = view,
         [_, _ | _] = legal,
         base,
         opts
       ) do
    values = values(view, legal, opts)
    {choice, reason} = pick(values, base.rulebook, opts[:veto])
    %{base | choice: choice, reason: reason, values: values}
  end

  defp search(%SeatView{variant: :finnish, phase: :bidding} = view, legal, base, opts) do
    partner = Types.partner_position(view.position)

    with true <- :pass in legal,
         false <- match?({^partner, _}, view.highest_bid),
         [_ | _] = bids <- for({:bid, n} <- legal, do: n) do
      bid = if match?({:bid, _}, base.rulebook), do: base.rulebook, else: {:bid, Enum.min(bids)}
      take(view, bid, base, opts)
    else
      _ -> base
    end
  end

  defp search(_view, _legal, base, _opts), do: base

  # Every candidate is played in the same worlds.
  defp values(view, legal, opts) do
    worlds = worlds(view, opts)

    Map.new(legal, fn action ->
      total =
        Enum.sum_by(worlds, &Rollout.value(Rollout.run(&1, view.position, action), view.position))

      {action, total / length(worlds)}
    end)
  end

  defp take(view, {:bid, amount} = bid, base, opts) do
    team = Knowledge.my_team(view)

    outcomes =
      for world <- worlds(view, opts),
          final = Rollout.run(world, view.position, bid),
          final.last_hand.bidding_team == team,
          do: final.last_hand.made

    made = Enum.count(outcomes, & &1)
    rate = if outcomes == [], do: 0.0, else: made / length(outcomes)
    choice = if rate >= opts[:threshold], do: bid, else: :pass
    share = "#{round(rate * 100)}% of worlds"
    says = "Rulebook says #{label(base.rulebook)}"

    reason =
      cond do
        outcomes == [] -> "#{says}; search never holds #{amount}, so pass."
        choice == base.rulebook -> "#{says}; search agrees: #{amount} is made in #{share}."
        true -> "#{says}; search makes #{amount} in #{share}, so #{label(choice)}."
      end

    %{base | choice: choice, reason: reason, values: %{bid => rate, :pass => opts[:threshold]}}
  end

  defp worlds(view, opts) do
    rng = Determinizer.rng(:erlang.phash2({opts[:seed], position_key(view)}))

    {worlds, _rng} =
      Enum.flat_map_reduce(1..opts[:worlds], rng, fn _, rng ->
        case Determinizer.sample(view, rng) do
          {:ok, world, rng} -> {[Rollout.state(view, world)], rng}
          {:error, :no_world, rng} -> {[], rng}
        end
      end)

    if worlds == [], do: raise("no consistent world"), else: worlds
  end

  defp position_key(view) do
    {view.position, view.hand_number, view.hand, view.bids, view.tricks, view.current_trick,
     view.cumulative_scores}
  end

  defp rank_label(14), do: "A"
  defp rank_label(13), do: "K"
  defp rank_label(12), do: "Q"
  defp rank_label(11), do: "J"
  defp rank_label(rank), do: Integer.to_string(rank)

  defp suit_symbol(:hearts), do: "♥"
  defp suit_symbol(:diamonds), do: "♦"
  defp suit_symbol(:clubs), do: "♣"
  defp suit_symbol(:spades), do: "♠"
end

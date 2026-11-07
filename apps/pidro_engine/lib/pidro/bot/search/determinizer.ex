defmodule Pidro.Bot.Search.Determinizer do
  @moduledoc """
  Deals the cards a seat has not seen to the other seats, keeping every
  public fact true.

  A world is one way the hidden cards could lie. The unseen cards are the
  full deck minus the seat's own hand, the cards played this hand, the cards
  killed, and the seat's own folded cards. Sampling reads the `SeatView`
  only, threads an explicit `:rand` state, and never touches a game's chance
  stream, so a seed reproduces every world.

  ## In the auction

  The other three seats get nine unseen cards each and the remaining sixteen
  form the deck, in a uniformly random order. Nothing else is known yet.

  ## In play

  Sampling is constructive, with rejection only for what construction does
  not see, because rejection alone almost never hits a consistent deal late
  in a hand. A deal is the cards in each seat's roles: a non-dealer's kept
  trumps, its first-deal discards and its draws; the dealer's first deal and
  the pack left for its rob. The real deal is uniform over those, so each
  count (a seat's trumps, the dealer's first-deal and pack trumps) is drawn
  by the number of deals that give it, and then the cards go out at random. A
  deal that breaks a fact left to rejection is drawn again, which keeps the
  draw uniform over the deals it accepts. After 200 failed attempts the
  sample is an error and the caller decides without that world.

  Checked on random games, where the auction and the play say nothing about
  hands: at the opening lead the sampled chance that a seat holds a given
  trump matches how often it does (within 0.02 in every decile), and
  non-dealers' trump counts match to 0.01. The dealer's are 0.06 low.

  1. **The dealer** (when it is another seat) gets a pool through the same
     rob the engine runs. Its nine first-deal cards come from the unseen
     cards plus the cards it has played; its number of first-deal trumps is
     drawn among the counts that give the hand size the table sees. The `r`
     cards left after the second deal (`r` is 16 minus what the non-dealers
     drew) join its trumps as the pool, and
     `Pidro.Game.DealerRob.select_best_cards/2` picks its hand, so its bias to
     point cards is the engine's own. A dealer with six first-deal trumps does
     not rob and the pack stays undealt. Rejected: a hand without every card
     the dealer has played, or a cold dealer holding a trump.
  2. **Every other unseen trump** is in a hand: the first deal's discards
     hold no trump. A non-dealer drew `cards_requested` cards and kept only
     trumps, so the rest of its hand is trumps, and any of its trumps may be
     the kept ones. An eliminated seat holds no trump and folded only
     non-trumps.
  3. **When the seat itself dealt**, an unseen trump its own six cards
     outrank in the rob may instead be in its rob discards; how many are is
     drawn with the same weighting.

  ## Not modelled

  What the auction says about hands (a seat that bid 10 holds as many
  worlds as one that passed), the order the rulebook plays cards in, and
  the seat's own discards, which the view does not keep: they count as
  unseen and may land in another seat's hand. A dealer's killed cards are
  public, so a dealer that killed holds six first-deal trumps here.
  """

  alias Pidro.Bot.Knowledge
  alias Pidro.Core.{Card, Deck, SeatView, Types}
  alias Pidro.Game.DealerRob

  @type rng :: :rand.state()
  @type world :: %{
          hands: %{Types.position() => [Types.card()]},
          folded: %{Types.position() => [Types.card()]},
          deck: [Types.card()],
          discards: [Types.card()],
          dealer_pool: [Types.card()] | nil
        }

  @tries 200
  @first_deal 9
  @pack_after_deal 16

  @doc """
  Returns a seeded `:rand` state for `seed`.
  """
  @spec rng(integer()) :: rng()
  def rng(seed), do: :rand.seed_s(:exsss, {seed, 0x5EA4C, 379})

  @doc """
  Returns the cards the seat in `view` has not seen this hand.
  """
  @spec unseen(SeatView.t()) :: [Types.card()]
  def unseen(%SeatView{} = view) do
    known =
      MapSet.new(
        view.hand ++
          Knowledge.played_cards(view) ++
          Enum.concat(Map.values(view.killed_cards)) ++
          view.players[view.position].revealed_cards
      )

    Enum.reject(Deck.ordered(), &MapSet.member?(known, &1))
  end

  @doc """
  Samples one world for the seat in `view`, in the auction or in play.

  ## Returns

  `{:ok, world, rng}`, or `{:error, :no_world, rng}` when no consistent deal
  was found in #{@tries} attempts.
  """
  @spec sample(SeatView.t(), rng()) :: {:ok, world(), rng()} | {:error, :no_world, rng()}
  def sample(%SeatView{phase: :bidding} = view, rng) do
    {cards, rng} = :rand.shuffle_s(unseen(view), rng)
    {hands, deck} = deal_nine(others(view), cards, %{})
    {:ok, %{hands: hands, folded: %{}, deck: deck, discards: [], dealer_pool: nil}, rng}
  end

  def sample(%SeatView{phase: :playing} = view, rng), do: attempt(view, rng, @tries)

  defp deal_nine([], deck, hands), do: {hands, deck}

  defp deal_nine([pos | rest], cards, hands) do
    {hand, cards} = Enum.split(cards, @first_deal)
    deal_nine(rest, cards, Map.put(hands, pos, hand))
  end

  defp attempt(_view, rng, 0), do: {:error, :no_world, rng}

  defp attempt(view, rng, tries) do
    {trumps, plain} = Enum.split_with(unseen(view), &Card.is_trump?(&1, view.trump_suit))
    {trumps, rng} = :rand.shuffle_s(trumps, rng)
    {plain, rng} = :rand.shuffle_s(plain, rng)

    with {:ok, choice, rng} <- weighted_pick(options(view, trumps), rng),
         {:ok, world, rng} <- deal(view, choice, trumps, plain, rng) do
      {:ok, world, rng}
    else
      {:reject, rng} -> attempt(view, rng, tries - 1)
    end
  end

  # Every count vector that keeps the public facts, weighted by the number of
  # deals that give it. A seat's trumps take `C(size, n)` slot choices.
  defp options(%SeatView{position: me, current_dealer: me} = view, trumps) do
    optional = Enum.count(trumps, &own_rob_discard?(view, &1))
    bounds = bounds(view)

    slots =
      Enum.sum_by(seats(view), &(view.players[&1].hand_count + view.players[&1].folded_count))

    plain = length(unseen(view)) - length(trumps)

    # Robbed trumps leave hand slots to non-trumps, so the slot fillings vary.
    for robbed <- 0..optional//1,
        held = length(trumps) - robbed,
        counts <- splits(bounds, held) do
      {{:robbed, robbed, counts},
       slot_ways(bounds, counts) * drawn_ways(view, counts) * choose(optional, robbed) *
         falling(held, held) *
         falling(plain, slots - held)}
    end
  end

  # The dealer's region is its first deal (9 slots, `k` trumps) and the pack
  # left after the second deal (`leftover` slots, `j` trumps). It holds the
  # cards the dealer played and every unseen trump no other seat holds.
  defp options(%SeatView{current_dealer: dealer} = view, trumps) do
    played = length(played_by(view, dealer))
    leftover = leftover(view)
    bounds = bounds(view)

    for held <- 0..length(trumps),
        counts <- splits(bounds, held),
        region = length(trumps) - held + played,
        k <- 0..min(region, @first_deal),
        j = region - k,
        dealer_fits?(view, k, j, leftover, played) do
      {{:dealer, counts, k, j},
       slot_ways(bounds, counts) * drawn_ways(view, counts) * choose(@first_deal, k) *
         choose(leftover, j) *
         falling(region, played)}
    end
  end

  # The rob keeps the trumps first, then non-trumps, up to six cards; six or
  # more first-deal trumps skip it. The kept cards must have the size the
  # table sees, a cold dealer's trumps were all played, and an active one's
  # hand holds the rest.
  defp dealer_fits?(view, k, j, leftover, played) do
    public = view.players[view.current_dealer]
    rob? = k < 6 and leftover > 0
    size = if rob?, do: min(6, k + leftover), else: k
    kept = if rob?, do: min(k + j, 6), else: k

    j <= leftover and size == public.hand_count + public.folded_count + played and
      if(public.eliminated?,
        do: kept == played,
        else: kept in played..(played + public.hand_count)
      )
  end

  defp deal(view, {:robbed, robbed, counts}, trumps, plain, rng) do
    {optional, required} = Enum.split_with(trumps, &own_rob_discard?(view, &1))
    {gone, kept} = Enum.split(optional, robbed)
    {held, rng} = :rand.shuffle_s(required ++ kept, rng)
    {hands, folded, [], plain} = deal_seats(view, counts, held, plain)

    {:ok, %{hands: hands, folded: folded, deck: [], discards: gone ++ plain, dealer_pool: nil},
     rng}
  end

  defp deal(
         %SeatView{current_dealer: dealer, trump_suit: trump} = view,
         choice,
         trumps,
         plain,
         rng
       ) do
    {:dealer, counts, k, j} = choice
    played = played_by(view, dealer)
    public = view.players[dealer]
    leftover = leftover(view)

    {mine, trumps} = Enum.split(trumps, k + j - length(played))
    {region, rng} = :rand.shuffle_s(played ++ mine, rng)
    {first, pack_trumps} = Enum.split(region, k)
    {thrown, plain} = Enum.split(plain, @first_deal - k)
    {pack_plain, plain} = Enum.split(plain, leftover - j)
    {pack, rng} = :rand.shuffle_s(pack_trumps ++ pack_plain, rng)
    {hands, folded, [], plain} = deal_seats(view, counts, trumps, plain)

    # Without a rob the leftover pack stays undealt, as in the engine.
    {start, pool, deck} =
      if k >= 6 or leftover == 0,
        do: {first, nil, pack},
        else: {DealerRob.select_best_cards(first ++ pack, trump), first ++ pack, []}

    hand = start -- played

    if played -- start == [] do
      {held, faces} = if public.eliminated?, do: {[], hand}, else: {hand, []}

      {:ok,
       %{
         hands: Map.put(hands, dealer, held),
         folded: if(faces == [], do: folded, else: Map.put(folded, dealer, faces)),
         deck: deck,
         discards: thrown ++ ((pool || []) -- start) ++ plain,
         dealer_pool: pool
       }, rng}
    else
      {:reject, rng}
    end
  end

  # Gives each seat its trumps and fills its hand, then its folded faces.
  defp deal_seats(view, counts, trumps, plain) do
    view
    |> seats()
    |> Enum.zip(counts)
    |> Enum.reduce({%{}, %{}, trumps, plain}, fn {pos, n}, {hands, folded, trumps, plain} ->
      public = view.players[pos]
      {held, trumps} = Enum.split(trumps, n)
      {filler, plain} = Enum.split(plain, public.hand_count - n)
      {faces, plain} = Enum.split(plain, public.folded_count)
      folded = if faces == [], do: folded, else: Map.put(folded, pos, faces)
      {Map.put(hands, pos, held ++ filler), folded, trumps, plain}
    end)
  end

  # `{size, min}` per seat: a non-dealer drew `cards_requested` cards, so the
  # rest of its hand is trumps. A cold seat has no slots.
  defp bounds(view) do
    for pos <- seats(view) do
      size = view.players[pos].hand_count
      {size, max(size - Map.get(view.cards_requested, pos, 6), 0)}
    end
  end

  # A non-dealer's trumps are the ones it kept from the first deal plus the
  # ones it drew; any of them could have been the kept ones, so a hand with
  # more trumps than it kept arises in more deals.
  defp drawn_ways(view, counts) do
    view
    |> seats()
    |> Enum.zip(counts)
    |> Enum.map(fn {pos, n} ->
      public = view.players[pos]
      gone = length(played_by(view, pos)) + length(Map.get(view.killed_cards, pos, []))
      total = public.hand_count + public.folded_count + gone
      choose(n + gone, total - Map.get(view.cards_requested, pos, 6))
    end)
    |> Enum.product()
  end

  defp slot_ways(bounds, counts) do
    bounds
    |> Enum.zip(counts)
    |> Enum.map(fn {{size, _}, n} -> choose(size, n) end)
    |> Enum.product()
  end

  # Every way to split `total` trumps over seats of `{size, min}`.
  defp splits([], 0), do: [[]]
  defp splits([], _total), do: []

  defp splits([{size, min} | rest], total) do
    for n <- min..min(size, total)//1, tail <- splits(rest, total - n), do: [n | tail]
  end

  defp weighted_pick(options, rng) do
    case Enum.sum_by(options, &elem(&1, 1)) do
      0 ->
        {:reject, rng}

      sum ->
        {pick, rng} = :rand.uniform_s(sum, rng)
        {:ok, weighted(options, pick), rng}
    end
  end

  defp weighted([{value, weight} | rest], pick),
    do: if(pick <= weight, do: value, else: weighted(rest, pick - weight))

  defp choose(n, k) when k < 0 or k > n, do: 0
  defp choose(n, k), do: div(falling(n, k), falling(k, k))

  defp falling(n, k) when k < 0 or k > n, do: 0
  defp falling(n, k), do: Enum.product((n - k + 1)..n//1)

  # An unseen trump may be off the table only if the seat itself dealt and
  # its own six cards outrank it in the rob selection.
  defp own_rob_discard?(%SeatView{position: me, current_dealer: me} = view, card) do
    start = view.hand ++ played_by(view, me)

    leftover(view) > 0 and
      card not in DealerRob.select_best_cards([card | start], view.trump_suit)
  end

  defp own_rob_discard?(_view, _card), do: false

  # The pack holds 16 cards after the first deal; the non-dealers draw first.
  defp leftover(%SeatView{} = view) do
    drawn = view.cards_requested |> Map.drop([view.current_dealer]) |> Map.values() |> Enum.sum()
    max(@pack_after_deal - drawn, 0)
  end

  defp played_by(%SeatView{} = view, pos) do
    tricks = view.tricks ++ List.wrap(view.current_trick)
    for trick <- tricks, {^pos, card} <- trick.plays, do: card
  end

  # The other seats that are not the dealer.
  defp seats(%SeatView{} = view), do: others(view) -- [view.current_dealer]

  defp others(%SeatView{position: me}), do: Types.all_positions() -- [me]
end

defmodule Pidro.Bot.Thresholds do
  @moduledoc """
  Every constant the rulebook bot bids by, in one place.

  A suit's bid estimate sums sure points, the held Fives weighted by how
  protected they are, half-credit for the Jack and Ten, a bonus for holding
  the top trumps, and a bonus for the dealer. Finnish adds trump length and
  an allowance to contest cheap opposing bids.

  The original calibration valued a protected Five at 3 and gave one top
  trump control credit from three trumps. PID-271 tuned length, competition
  and partner raises on paired self-play (seed 271), then checked fresh seeds
  272 and 273: 51.9% and 52.4% wins against the original bidder. Four updated
  seats made 75.8% of contracts versus 76.5% before. The half-point competition
  allowance kept nearly all the gain of larger margins with fewer sets.

  PID-365 made the estimate a ceiling: the bot bids the minimum it needs,
  one more to shut out an opponent still to speak when the estimate clears
  the minimum by three, and raises a partner by one step. With the raise
  capped, a partner margin of two beat one on seed 365 (50.3% of 6,000
  games, fewer sets, 75.4% of raises made against 73.6%), so both variants
  use two. On held-out seeds 366 and 367 the new bidder beat the PID-271
  bidder; see `docs/bot-difficulty.md`.

  PID-377 lets a Finnish bot volunteer the minimum on an estimate up to a
  point short of it. On seed 3771 a margin of half a point left a third of
  hands as forced dealer 6s; a full point cut them from 41% to 23% on
  held-out seeds 3772 and 3773, with 78% of volunteered 6s made.

  PID-136 turned the positions where `Pidro.Bot.Search` overruled the
  rulebook most into the holding table and the Five's cover. On seed 1360
  the holding table won 52.7% to 54.4% against the PID-377 bidder as its
  bonuses rose; past A K Q 7, A K J 6.5, A Q J 5.5 and A K 5 a further
  point won 50.4% to 51.0% head to head while sets climbed, so it stops
  there. An unprotected Five worth 2, 1 or 0.5 played the same within 0.3
  points; what paid was that a King no longer covers it (51.4% against
  50.1%). At 0.5 no hand with an uncovered Five comes within the volunteer
  margin. Held out on seeds 1361 and 1362 the new rulebook won 60.2% and
  59.1%, Louisiana 59.7% on seed 1365; see `docs/bot-difficulty.md`.
  """

  @values %{
    ace: 1,
    two: 1,
    jack_or_ten: 0.5,
    five_protected: 3,
    five_unprotected: 0.5,
    five_protection_trumps: 4,
    five_protection_trumps_with_ace: 3,
    control_ace_king: 3,
    control_one_honour: 2,
    control_one_honour_min_trumps: 3,
    dealer_bonus: 1,
    trump_length: 0.25,
    trump_length_cap: 0.75,
    cheap_contract_margin: 0.5,
    volunteer_margin: 1.0,
    overbid_partner_margin: 2,
    shut_out_margin: 3
  }

  @holdings [
    {[14, 13, 12], 7},
    {[14, 13, 11], 6.5},
    {[14, 12, 11], 5.5},
    {[14, 13], 5}
  ]

  @typedoc "The name of a bidding constant."
  @type name ::
          :ace
          | :two
          | :jack_or_ten
          | :five_protected
          | :five_unprotected
          | :five_protection_trumps
          | :five_protection_trumps_with_ace
          | :control_ace_king
          | :control_one_honour
          | :control_one_honour_min_trumps
          | :dealer_bonus
          | :trump_length
          | :trump_length_cap
          | :cheap_contract_margin
          | :volunteer_margin
          | :overbid_partner_margin
          | :shut_out_margin

  @doc """
  Returns the value of one bidding constant.

  - `:ace`, `:two` - sure points for holding the Ace or the 2 of the suit
  - `:jack_or_ten` - half-credit for each of the Jack and the Ten
  - `:five_protected` / `:five_unprotected` - value of each held Five
  - `:five_protection_trumps` - trumps held, the Five included, that protect it
  - `:five_protection_trumps_with_ace` - the same with the Ace held; a King
    does not cover a Five, since the Ace can take both
  - `:control_ace_king` - bonus for the Ace and King together, when no
    holding in `holdings/0` applies
  - `:control_one_honour` - bonus for one of them with enough length
  - `:control_one_honour_min_trumps` - the length that bonus and the
    holdings need
  - `:dealer_bonus` - added when the bidder is the dealer, who robs the pack
  - `:trump_length` / `:trump_length_cap` - Finnish bonus per trump beyond two,
    capped to avoid double-counting the protection and control bonuses
  - `:cheap_contract_margin` - Finnish allowance below the next bid when
    contesting an opponent's 6 or 7; never applied over a partner
  - `:volunteer_margin` - Finnish allowance below the minimum when opening
    or outbidding an opponent, so fewer hands end in a forced dealer 6
  - `:overbid_partner_margin` - how far above partner's bid the estimate must
    reach before the bot raises partner by one
  - `:shut_out_margin` - how far above the minimum the estimate must reach
    before a seat with an opponent still to speak bids one more

  ## Examples

      iex> Pidro.Bot.Thresholds.get(:overbid_partner_margin)
      2
  """
  @spec get(name()) :: number()
  def get(name), do: Map.fetch!(@values, name)

  @doc """
  Returns all bidding constants.
  """
  @spec all() :: %{name() => number()}
  def all, do: @values

  @doc """
  Returns the control bonus by holding, best first: the trump ranks held
  and the bonus they earn with at least `:control_one_honour_min_trumps`
  trumps: the Ace with the King, or with two of the King, Queen and Jack.
  A hand that holds none of them takes the
  `:control_ace_king` or `:control_one_honour` bonus.

  ## Examples

      iex> Pidro.Bot.Thresholds.holdings() |> hd()
      {[14, 13, 12], 7}
  """
  @spec holdings() :: [{[Pidro.Core.Types.rank()], number()}]
  def holdings, do: @holdings
end

defmodule Pidro.Bot.Thresholds do
  @moduledoc """
  Every constant the rulebook bot bids by, in one place.

  A suit's bid estimate sums sure points, the held Fives weighted by how
  protected they are, half-credit for the Jack and Ten, a bonus for holding
  the top trumps, and a bonus for the dealer. Finnish adds trump length and
  an allowance to contest cheap opposing bids. Louisiana keeps the original
  estimate.

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
  """

  @values %{
    ace: 1,
    two: 1,
    jack_or_ten: 0.5,
    five_protected: 3,
    five_unprotected: 2,
    five_protection_trumps: 4,
    five_protection_trumps_with_honour: 3,
    control_ace_king: 3,
    control_one_honour: 2,
    control_one_honour_min_trumps: 3,
    dealer_bonus: 1,
    trump_length: 0.25,
    trump_length_cap: 0.75,
    cheap_contract_margin: 0.5,
    overbid_partner_margin: 2,
    shut_out_margin: 3
  }

  @typedoc "The name of a bidding constant."
  @type name ::
          :ace
          | :two
          | :jack_or_ten
          | :five_protected
          | :five_unprotected
          | :five_protection_trumps
          | :five_protection_trumps_with_honour
          | :control_ace_king
          | :control_one_honour
          | :control_one_honour_min_trumps
          | :dealer_bonus
          | :trump_length
          | :trump_length_cap
          | :cheap_contract_margin
          | :overbid_partner_margin
          | :shut_out_margin

  @doc """
  Returns the value of one bidding constant.

  - `:ace`, `:two` - sure points for holding the Ace or the 2 of the suit
  - `:jack_or_ten` - half-credit for each of the Jack and the Ten
  - `:five_protected` / `:five_unprotected` - value of each held Five
  - `:five_protection_trumps` - trumps held, the Five included, that protect it
  - `:five_protection_trumps_with_honour` - the same with the Ace or King held
  - `:control_ace_king` - bonus for the Ace and King together
  - `:control_one_honour` - bonus for one of them with enough length
  - `:control_one_honour_min_trumps` - the length that bonus needs
  - `:dealer_bonus` - added when the bidder is the dealer, who robs the pack
  - `:trump_length` / `:trump_length_cap` - Finnish bonus per trump beyond two,
    capped to avoid double-counting the protection and control bonuses
  - `:cheap_contract_margin` - Finnish allowance below the next bid when
    contesting an opponent's 6 or 7; never applied over a partner
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
end

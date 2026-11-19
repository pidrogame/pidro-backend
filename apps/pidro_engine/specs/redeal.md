# CRITICAL IMPLEMENTATION DETAIL: Finnish Pidro Dealer Advantage & Kill Rules

## Context

You are implementing the Finnish variant of Pidro. The re-deal phase has special mechanics
that create strategic asymmetry and information hiding. This is CRITICAL to get right.

Look at specs/\* and \_masterplan.md for what we've implemented.

## The Re-Deal Sequence (After Trump is Selected)

### Phase 1: Non-Dealers Discard and Receive

1. Each non-dealer discards all non-trump cards (keeping trump suit + wrong 5)
2. Each non-dealer is dealt NEW cards until they have exactly 6 cards total
3. Cards dealt in clockwise order starting left of dealer

**Information Leak**: Dealer observes how many cards each non-dealer requests.

- If player requests 5 cards → they had 1 trump in original hand
- If player requests 0 cards → they had 6+ trump in original hand

### Phase 2: Dealer's Privilege ("Robbing the Pack")

1. Dealer keeps their current hand (trump cards only)
2. Dealer takes ALL remaining undealt cards from deck
3. Dealer combines: `their_hand ++ remaining_deck_cards`
4. Dealer privately views this combined pool
5. Dealer selects the best 6 cards from this pool
6. Dealer discards the rest face-down

**Key Points**:

- Dealer sees MORE cards than anyone else (could be 10+ cards to choose from)
- No one knows how many trump the dealer originally had
- Dealer can cherry-pick the strongest 6 cards

### Phase 3: Kill Rule (If Any Player Has >6 Trump)

If after re-deal, ANY player (including dealer) has more than 6 trump cards:

1. Player MUST "kill" excess cards to get down to 6 total
2. Killed cards placed face-up on table, declared "out of game"
3. **Cannot kill point cards** (A, J, 10, 5, 5, 2)
4. Can only kill non-point trump (K, Q, 9, 8, 7, 6, 4, 3)
5. There are only six point trumps, so a kill down to 6 always works
6. Killed cards stay face up, out of the hand, and are **never played** (see `guides/game_rules.md`, Kill Rule)

## Edge Cases to Handle

### Edge 1: Dealer Gets No Cards

If all 3 non-dealers request 6 cards each:

- 3 × 6 = 18 cards dealt
- Remaining deck after initial deal: 16 cards
- Available to dealer: 16 - 18 = -2 (impossible) or 0 if they had trump
  This means dealer must have had 2+ trump to even have a hand

### Edge 2: Player Has 7 Point Cards

Impossible: there are only six point trumps (A, J, 10, Right-5, Wrong-5, 2), so a kill down to 6 always works.

### Edge 3: Dealer Has >6 Trump After Robbing

Dealer's hand: 2 trump
Remaining deck: 8 trump, 2 non-trump
Dealer combines → 10 trump + 2 non-trump = 12 cards

- Dealer keeps best 6 trump
- Discards 4 trump + 2 non-trump

## Data Structure Requirements

```elixir
# Game state during re-deal must track:
%{
  phase: :second_deal,
  dealer_position: :north,

  # Visible information
  cards_requested: %{
    east: 3,   # Everyone can deduce: East had 3 trump
    south: 5,  # South had 1 trump
    west: 0    # West had 6+ trump
  },

  # Hidden information (only dealer knows)
  dealer_pool: [cards],  # Dealer's hand + remaining deck
  dealer_pool_size: 8,   # How many cards dealer saw

  # Kill tracking
  killed_cards: %{
    west: [{:king, :hearts}],  # West killed K♥; it is never played
  }
}
```

## Implementation Checklist

- [ ] Dealer combines hand + deck into single pool
- [ ] Dealer selects 6 from pool privately
- [ ] Track cards_requested per player (public info)
- [ ] Track dealer_pool_size (for later analysis, not visible to players)
- [ ] Kill validation: only allow non-point cards
- [ ] Kill mechanic: killed cards are never played
- [ ] Property test: dealer always sees >= 6 cards (or game is invalid)
- [ ] Property test: killed cards are non-point

## Why This Matters

- Dealer has 20-30% higher chance of strong hand (depends on remaining trump)
- Information asymmetry is core game mechanic (not a bug!)
- Kill rule prevents dealer from being TOO powerful (killed cards lie face up for everyone to see)

## Current situation

### Critical Issue Found!

Your property on lines 548-562 is TOO STRICT:

```elixir
# CURRENT (WRONG):
property "player hands never exceed 9 cards initially, then 6 after re-deal" do
  check all game <- any_game_state_generator() do
    max_cards = case game.phase do
      :not_started -> 0
      :bidding -> 9
      _ -> 6  # ❌ THIS IS WRONG!
    end
```

Should be

```elixir
property "player hands are at most 6 cards after re-deal, UNLESS they have excess trump" do
  check all game <- post_redeal_game_generator() do
    game.players
    |> Enum.all?(fn player ->
      hand_size = length(player.hand)
      trump_count = count_trump(player.hand, game.trump_suit)

      # Either exactly 6, OR more than 6 but all trump
      (hand_size == 6) or (hand_size == trump_count and trump_count > 6)
    end)
    |> assert()
  end
end
```

### more examples

1. Dealer's Robbing Sequence (Missing Detail)
   The current property says "dealer takes remaining cards and selects 6" but doesn't specify:

```elixir
# ADD THIS PROPERTY:
property "dealer combines remaining deck WITH own hand before selecting 6" do
  check all game <- pre_dealer_selection_generator() do
    dealer = find_dealer(game)
    remaining_cards = game.deck.cards

    # Dealer should see: their_hand ++ remaining_deck
    available_to_dealer = length(dealer.hand) + length(remaining_cards)

    # Then picks best 6 from this pool
    {:ok, game_after} = Dealer.select_cards(game)
    dealer_after = find_dealer(game_after)

    assert length(dealer_after.hand) == 6
    assert dealer_after.selection_pool_size == available_to_dealer
  end
end
```

2. Dealer's Informational Advantage (Not Mentioned)
   Add this to game properties:

```elixir
property "dealer knows how many trump each player started with (but not their own)" do
  check all game <- post_discard_pre_redeal_generator() do
    dealer = find_dealer(game)

    # For each non-dealer, dealer can deduce trump count
    # by seeing how many cards they need to reach 6
    non_dealers = get_non_dealers(game)

    Enum.each(non_dealers, fn player ->
      cards_requested = 6 - length(player.hand)
      trump_count = length(player.hand)

      # Dealer can see this information
      assert game.visible_to_dealer[player.id] == %{
        trump_count: trump_count,
        cards_requested: cards_requested
      }
    end)

    # But other players don't know dealer's trump count
    assert game.hidden_from_players[:dealer_trump_count] == true
  end
end
```

3. Kill Rule First Card Mechanic (Wrong: killed cards are never played; see `guides/game_rules.md`, Kill Rule)
   The spec mentions killing cards, but doesn't mention that the top killed card is played first:

```elixir

property "when player kills cards, top card is played on first trick" do
  check all game <- player_with_killed_cards_generator() do
    player = find_player_with_killed_cards(game)
    top_killed_card = List.first(player.killed_cards)

    # Start playing phase
    {:ok, game_after_first_play} = Game.play_first_trick(game)

    # Player with killed cards must play top killed card
    assert played_card(game_after_first_play, player.id) == top_killed_card
  end
end

property "killed cards count toward player's 6-card hand for first trick" do
  check all player <- player_with_killed_cards_generator() do
    # If player has 5 in hand + 1 killed = still counts as 6 for play
    assert effective_hand_size(player) == 6
  end
end
```

4. Order of Re-deal (Could Be Clearer)
   Add explicit sequencing:

```elixir
property "dealer can have >6 cards if remaining deck has many trump" do
  check all game <- dealer_with_excess_trump_generator() do
    dealer = find_dealer(game)

    # If after combining deck + hand, dealer has >6 trump
    if dealer.trump_count > 6 do
      # Dealer keeps ALL trump (per Finnish rules from pagat.com)
      assert length(dealer.hand) > 6

      # Killed cards are never played (see guides/game_rules.md, Kill Rule)
    end
  end
end
```

5. What If Dealer Has >6 Trump Too? (Edge Case)
   This isn't mentioned - what if the dealer ends up with 7+ trump after robbing?

```elixir
property "dealer can have >6 cards if remaining deck has many trump" do
  check all game <- dealer_with_excess_trump_generator() do
    dealer = find_dealer(game)

    # If after combining deck + hand, dealer has >6 trump
    if dealer.trump_count > 6 do
      # Dealer keeps ALL trump (per Finnish rules from pagat.com)
      assert length(dealer.hand) > 6

      # Killed cards are never played (see guides/game_rules.md, Kill Rule)
    end
  end
end
```

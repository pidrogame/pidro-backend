# Finnish Pidro Game Rules

Complete rules for the Finnish variant of Pidro as implemented in this engine.

## Overview

Finnish Pidro is a trick-taking card game for 4 players in 2 teams. Only trump cards are played, and the first team to reach 62 points wins.

## Setup

### Players and Teams

- **4 Players**: North, East, South, West
- **2 Teams**:
  - North/South (partners sit opposite)
  - East/West (partners sit opposite)

### The Deck

Standard 52-card deck (no jokers).

### Dealer Selection

1. Each player cuts the deck
2. Player with highest cut card becomes dealer
3. Ties: re-cut until resolved

## Game Sequence

### 1. Initial Deal

- Dealer deals 9 cards to each player
- Dealt in 3-card batches clockwise
- 16 cards remain in the deck (the "pack")

### 2. Bidding

Starting left of dealer, each player either:
- **Bids** 6-14 points (must beat current highest bid)
- **Passes** (cannot bid again this hand)

**Special Rules:**
- If all players pass, dealer **must** bid 6 (forced bid)
- Bidding ends when dealer's turn is reached after bids
- At bid of 14, another player can bid 14 to top it (last 14 wins)

**Example Bidding Sequence:**
```
West (left of South dealer): Bid 8
North: Pass
East: Bid 10
South (dealer): Bid 11
West: Pass
East: Pass
→ South wins with bid of 11
```

### 3. Trump Declaration

Bid winner declares trump suit (hearts, diamonds, clubs, or spades).

### 4. Automatic Discard

**All players automatically discard all non-trump cards**, with one exception:

**Wrong 5 Rule**: The 5 of the same-color suit is considered trump:
- Trump: Hearts → 5 of Diamonds is trump (wrong 5)
- Trump: Diamonds → 5 of Hearts is trump (wrong 5)
- Trump: Clubs → 5 of Spades is trump (wrong 5)
- Trump: Spades → 5 of Clubs is trump (wrong 5)

This means **15 trump cards** exist per hand (14 of trump suit + 1 wrong 5).

### 5. Second Deal (Redeal)

Non-dealers are dealt cards **in clockwise order** starting left of dealer:
- If player has <6 trump: dealt cards to reach 6
- If player has ≥6 trump: receives 0 cards
- Cards dealt from remaining deck (16 cards initially)

**Information Visibility:**
- All players see **how many cards** each non-dealer requested
- Nobody sees **which specific cards** were dealt

### 6. Dealer Rob

After second deal, dealer **combines their hand with all remaining deck cards** to form a pool, then:
- Selects **exactly 6 cards** from the pool
- Can select ANY 6 cards (can even discard trump)
- Unselected cards go to discard pile

**Information Visibility:**
- All players see **pool size** (dealer hand + remaining deck)
- Nobody sees **specific cards** in dealer's pool or final selection

### 7. Kill Rule

If any player (including dealer) has **more than 6 trump cards**, they must:

**Option A: Kill Down to 6**
- Discard non-point trump cards to reach exactly 6
- Can only kill: K, Q, 9, 8, 7, 6, 4, 3 (non-point trump)
- Cannot kill: A, J, 10, Right-5, Wrong-5, 2 (point cards)

**Option B: Keep All Cards**
- If player has 7+ point cards, cannot kill
- Player keeps all cards (>6 allowed)

**Killed Cards:**
- Placed face-up (visible to all) and out of the hand
- **Never played** this hand
- Never point cards, so killing never takes points out of play

### 8. Playing Tricks

**Trump-Only Rule**: Only trump cards can be played (core Finnish variant rule).

**Play Sequence:**
1. Leader (left of dealer first trick) plays any trump card
2. Other players (clockwise) each play one trump card
3. Highest trump card wins the trick
4. Winner leads next trick
5. Continue until all players are eliminated or out of cards

**Trump Ranking (Highest to Lowest):**
```
Ace > King > Queen > Jack > 10 > 9 > 8 > 7 > 6 > Right-5 > Wrong-5 > 4 > 3 > 2
```

**Going Cold (Elimination):**
- When a player has no trump cards left, they "go cold"
- Player reveals any remaining non-trump cards (shouldn't happen if rules followed)
- Player is eliminated from remaining tricks
- Play continues with remaining active players

**Hand Ends When:**
- All tricks are played, OR
- Only one team has active players remaining

### 9. Scoring

**Point Cards (14 points total per hand):**
- Ace: 1 point
- Jack: 1 point
- 10: 1 point
- Right 5 (5 of trump suit): 5 points
- Wrong 5 (5 of same-color suit): 5 points
- 2 of trump: 1 point

**Special 2 Rule:**
- Player who wins trick with 2 of trump **keeps 1 point** for themselves
- Remaining points from trick go to their team

**Bid Made/Failed:**

**Bidding Team:**
- **Made Bid**: If points taken ≥ bid amount, score points taken
- **Failed Bid**: If points taken < bid amount, **lose** bid amount (can go negative)

**Defending Team:**
- Always score points they took (regardless of bid result)

**Example:**
```
East/West bid 10, trump is hearts
East/West take: 8 points
North/South take: 6 points

Result:
- East/West: -10 (failed bid, lose 10)
- North/South: +6 (score what they took)
```

**Killed Cards:**
- Point cards are never killed, so killing never takes points out of play

### 10. Winning the Game

- First team to reach **62 cumulative points** wins
- If both teams reach 62 in same hand, **bidding team wins**
- Scores can go negative (failed bids)

### 11. Next Hand

- Dealer rotates clockwise (previous dealer's left neighbor becomes new dealer)
- Deck reshuffled
- Repeat from step 1

## Summary of Key Finnish Rules

1. **Trump Only**: Only trump cards can be played (non-trump discarded immediately)
2. **Wrong 5**: 5 of same-color suit is trump (15 trump cards total)
3. **Redeal**: Non-dealers dealt to 6 cards after discard
4. **Dealer Rob**: Dealer combines hand + deck, selects best 6
5. **Kill Rule**: Players with >6 trump must kill non-point cards (or keep all if 7+ point cards)
6. **Killed Cards**: Lie face up, visible to all, and are never played
7. **Going Cold**: Players eliminated when out of trump
8. **Information Asymmetry**: Only dealer sees full pool; others see counts only

## Differences from Other Variants

This Finnish variant differs from American/Norwegian Pidro:

- **Trump only** (Finnish) vs. must follow suit (others)
- **Wrong 5 is trump** (Finnish) vs. wrong 5 not used (others)
- **Dealer rob** (Finnish) vs. widow/kitty (others)
- **Kill rule** (Finnish) vs. fixed 6 cards (others)
- **Going cold** (Finnish) vs. play until all tricks done (others)

## Detailed Examples

### Example: Wrong 5 as Trump

```
Trump declared: Hearts

Trump cards (15 total):
- All hearts: A♥ K♥ Q♥ J♥ 10♥ 9♥ 8♥ 7♥ 6♥ 5♥ 4♥ 3♥ 2♥ (13 cards)
- PLUS wrong 5: 5♦ (same-color suit)
- PLUS any hearts from deck

Not trump:
- All diamonds except 5♦: A♦ K♦ Q♦ J♦ 10♦ 9♦ 8♦ 7♦ 6♦ 4♦ 3♦ 2♦
- All clubs: A♣ K♣ Q♣ J♣ 10♣ 9♣ 8♣ 7♣ 6♣ 5♣ 4♣ 3♣ 2♣
- All spades: A♠ K♠ Q♠ J♠ 10♠ 9♠ 8♠ 7♠ 6♠ 5♠ 4♠ 3♠ 2♠
```

### Example: Kill Rule

```
Player has 8 trump cards after dealer rob:
A♥ [1pt] K♥ Q♥ J♥ [1pt] 10♥ [1pt] 5♥ [5pt] 6♥ 4♥

Point cards: 4 (A, J, 10, 5) = cannot be killed
Non-point cards: 4 (K, Q, 6, 4) = killable

Must kill 2 cards to get to 6.
Valid kills: K♥, Q♥, 6♥, 4♥ (any 2)
Invalid kills: A♥, J♥, 10♥, 5♥ (point cards)

The engine kills the lowest: 4♥ and 6♥ (placed face-up, never played)
Final hand: A♥ K♥ Q♥ J♥ 10♥ 5♥ (6 cards)
```

### Example: Dealer Rob

```
Before rob:
- Dealer has: 3 trump cards
- Remaining deck: 10 cards (suppose 7 trump + 3 non-trump)
- Pool: 3 + 10 = 13 cards total

Dealer rob:
- Sees all 13 cards
- Selects best 6 trump cards
- Discards remaining 7 cards

Other players see:
- Pool size: 13 (public)
- Selected count: 6 (public)
- Specific cards: HIDDEN

Result:
- Dealer has exactly 6 cards
- Deck is empty
- Discard pile has 7 cards
```

## Strategy Tips

1. **Bidding**: Bid conservatively unless you have strong trump (A, 5, J, 10)
2. **Trump Selection**: Choose suit with most high cards and point cards
3. **Dealer Rob**: Prioritize point cards (5s especially) and high cards (A, K, Q)
4. **Kill Rule**: Keep point cards, kill low non-point trump
5. **Play**: Lead high to take points, save 5s for critical tricks
6. **Going Cold**: Try to avoid going cold early (lose control of play)

## Next Steps

- See [Getting Started](getting_started.md) to play your first game
- Read [Architecture](architecture.md) to understand the engine implementation
- Explore [Property Testing](property_testing.md) to see how rules are validated

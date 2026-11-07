# One production bot

Pidro uses one bot for normal games and Solo: the full Finnish rulebook,
previously called Regular. PID-137 removes the remaining client difficulty controls.
The engine owns legality, scoring, dealing, dealer rob and kills. The pure bot
chooses a legal action and an explanation from `SeatView`; the server owns
scheduling, cancellation and lifecycle recovery.

## Contract and compatibility

`Rulebook.decide(view, legal)` is the sole rulebook entry point. It uses public
card history, conservative bidding, Five protection and partnership conventions.
It receives its own hand and public information, never opponents' private hands,
the hidden deck or the authoritative chance stream.

The room API still accepts and echoes `bot_difficulty` values `random`, `basic`
and `smart` for older installed clients. All three resolve to `RulebookStrategy`;
omitting the field uses the same bot. This is deprecated compatibility data,
not a product setting. PID-137 removes the controls from mobile and web room
creation; new clients should omit the optional request field. Keep decoding the
existing room config response until a coordinated API change removes the field.

Initial seats, added bots, disconnect/departure substitutes, recovery and rematch
use the same rulebook. The separate passive policy for connected-human timeouts
is unchanged. Custom strategy modules are internal test/development hooks, not
client-selectable difficulty levels.

## Evaluation

From `apps/pidro_engine`, using the pinned toolchain:

```sh
mise exec -- mix pidro.selfplay --pairs 1000 --seed 71 --a rulebook --b random
mise exec -- mix pidro.selfplay --games 2000 --seed 1 --a rulebook --b random
mise exec -- mix pidro.selfplay --pairs 100 --seed 72 --a rulebook --b rulebook
```

CLI `random` is a random legal-action benchmark, never the normal room bot.
`regular` remains a CLI alias for `rulebook` so existing benchmark commands work;
`casual` is no longer supported.

`--pairs N` runs 2N games. Pair i uses engine seed `seed * 100_000 + i` twice,
with the compared policies swapping teams. Cuts and deck order match per hand;
decisions, trump choices, game lengths and random-policy actions can diverge.
The API also accepts candidate policy functions for future comparison without
adding them to the live server.

Reports include wins, pair sweeps/splits, contracts (including forced bids),
average winning bid, made/set rates, points lost to sets, Five outcomes and
decision times. Five metrics count cards in
completed tricks, including completed tricks in failed games:

- Captured: all Fives won, including the team's own Fives.
- Taken: opposing Fives captured.
- Lost: own Fives captured by opponents.

A lost Five is an observation, not automatically a tactical error. Non-timing
summaries are invariant under task concurrency. Timing includes seat-view
construction and scheduler delays; it is not a production latency guarantee.
The CLI exits with failure for an illegal action, crash, stall or action cap.
Inspect failures before interpreting win rates.

Keep the existing rulebook-vs-random and contract-quality gates. For a proposed
improvement, preserve a frozen reference, develop on separate seeds, and reserve
held-out seeds before tuning. Record partnership cases, contracts and Five
outcomes alongside wins. Human play remains necessary to assess partner trust.

## PID-365: bid what the contract needs

The bot used to bid its estimate; now it bids the minimum, one more to shut
out an opponent still to speak (estimate at least three over the minimum),
and raises a partner by one. Measured against the frozen PID-271 bidder: the
`Pidro.Bot.Bidding` of commit `7de5c8a`, compiled under another module name as
a candidate policy for `SelfPlay.run/1` (bidding only; play and trump
unchanged), 3,000 pairs per seed with teams swapped. Seed 365 chose the
partner margin (2 over 1); 366 and 367 were held out. Seeds 365–368 are used;
do not report them as unseen.

| Finnish, new / old  | seed 366        | seed 367        |
| ------------------- | --------------- | --------------- |
| wins                | 51.0% / 49.0%   | 51.2% / 48.8%   |
| contracts made      | 79.0% / 75.9%   | 79.7% / 76.5%   |
| sets                | 5,183 / 6,464   | 5,031 / 6,308   |
| points lost to sets | 32,498 / 44,874 | 31,486 / 43,833 |
| average winning bid | 6.22 / 6.70     | 6.21 / 6.71     |
| partner raises made | 79.0% / 68.3%   | 80.8% / 72.2%   |

Louisiana (seed 368, 1,000 pairs): 51.0% wins, 2,369 sets against 2,460.
Rulebook against random stays at 99.0% (`--pairs 1000 --seed 71`).

## PID-377: volunteer the minimum

Four PID-365 bidders left 41% of Finnish hands as a forced dealer 6. A
Finnish bot now opens or outbids an opponent at the minimum on an estimate
up to `volunteer_margin` (one point) short of it. Measured against the frozen
PID-365 bidder (`origin/main` at `e8da02f`, compiled under another module
name, bidding only), 3,000 pairs per seed. Seed 3771 chose the candidate:
margins of 0.5 (with a cheap-contract margin of 0.5 or 1.0) left 33% forced
6s; a margin of 1.0 makes a wider cheap margin a no-op. Seeds 3772 and 3773
were held out; 3774 checked Louisiana. Seeds 3770–3774 are used.

| Finnish, four seats of each  | seed 3772       | seed 3773       |
| ---------------------------- | --------------- | --------------- |
| forced dealer 6, new / old   | 23.3% / 40.8%   | 22.9% / 40.5%   |
| hands with two or more bids  | 29.3% / 16.4%   | 29.7% / 16.6%   |
| volunteered 6s made          | 77.6% / 78.1%   | 78.0% / 78.2%   |
| sets                         | 11,528 / 10,786 | 11,368 / 10,566 |
| points lost to sets          | 73,798 / 67,412 | 72,852 / 66,020 |
| average winning bid          | 6.36 / 6.22     | 6.36 / 6.22     |
| head to head, new team wins  | 52.8%           | 53.5%           |

Louisiana stays as it was: with the same margin its volunteered contracts
were made 69.2% of the time, under the 70% bar. Rulebook against random:
98.8% (`--pairs 1000 --seed 71`).

## Why one bot

The [PR #49](https://github.com/marcelfahle/pidro-backend/pull/49) experiment gave
Regular 51.65% wins against Casual on base seed 901 and 51.2% on base seed 71,
each across 1,000 pairs. Both used almost the same strategy; the measured gap did
not justify a player-facing choice. Those historical results describe the PR #49
implementation, not a currently available Casual policy. Do not tune against
those seeds and describe them as unseen afterward.

PID-136 is optional offline analysis of concrete weak decisions in the one bot.
It is not a release prerequisite or another difficulty tier. Guided tutorials
will use their own curated deals and scripted legal moves, with no changes to
normal match behavior.

## Simulator smoke (manual, still outstanding)

Use the iOS simulator and local backend; a web build is not required. Start the
backend with `mise exec -- iex -S mix phx.server` from the backend root and use
the monorepo's `just ios local` command for the mobile app.

- Enter Solo, confirm readiness, and play through at least hands 1, 2 and 3.
  Check dealer cuts appear only at game start, cards/dealer rotation are correct,
  and trick/scoring windows remain readable.
- Observe partner behavior: feed a Five under a safe partner Ace, avoid wasting a
  high trump over a safe partner, and retain Fives when the trick is unsafe.
- Finish and rematch. The room remains the same and bots continue playing.
- In a normal multiplayer room, disconnect a seated player, observe bot takeover,
  reconnect/reclaim the seat, and confirm the game continues correctly.
- After PID-137, create a normal room with bot seats and start Solo with no
  difficulty control. Until then, all legacy options should use the same bot.
- Record room, seat, hand/trick, visible cards, expected move and actual move for
  questionable decisions. Do not expose live hidden hands or chance to clients.

Automated tests cover omitted/legacy values, initial bots, takeover/recovery and
rematch. This document does not claim that a human simulator run was completed.

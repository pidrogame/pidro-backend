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

## PID-379: a search bot, measured (research only)

`Pidro.Bot.Search` deals out the cards a seat cannot see in K worlds that
keep every public fact (`Search.Determinizer`), plays each candidate card out
in every world with the rulebook in all four seats (`Search.Rollout`, engine
calls only), and keeps the card with the best average hand value. The
rulebook's card stands unless search prefers another by at least the veto
margin (0.4 hand points). In the auction search only decides whether to take
the rulebook's bid (or the minimum): it bids when its side makes the contract
in at least 70% of the worlds where it holds it. No table plays it; there is
no server reference to it.

```sh
mise exec -- mix pidro.selfplay --pairs 1000 --seed 3795 --a search --b rulebook --worlds 100 --veto 0.4 --report ../../docs/bot-search-disagreements.md
mise exec -- mix pidro.selfplay --pairs 1000 --seed 3796 --a search --b random
mise exec -- mix pidro.selfplay --pairs 1000 --seed 3797 --a search --b rulebook --veto 0
```

Held-out seeds, 1,000 pairs each (2,000 games, teams swapped), K = 100,
against the rulebook with PID-377's bidding:

| search vs …            | rulebook, veto 0.4 (3795) | random (3796)    | rulebook, no veto (3797) |
| ---------------------- | ------------------------- | ---------------- | ------------------------ |
| wins                   | 81.4%                     | 99.8%            | 81.7%                    |
| pairs swept            | 644 / 16                  | 996 / 0          | 648 / 14                 |
| contracts held         | 9,819 / 6,114             | 7,922 / 5,274    | 9,893 / 6,188            |
| contracts made         | 88.5% / 71.6%             | 93.9% / 28.9%    | 88.5% / 71.9%            |
| sets                   | 1,127 / 1,737             | 487 / 3,749      | 1,134 / 1,741            |
| average winning bid    | 6.45 / 6.72               | 6.40 / 7.47      | 6.45 / 6.71              |
| Fives taken / lost     | 8,455 / 3,952             | 9,713 / 2,596    | 8,320 / 3,963            |
| search p50 / p95 / max | 25 / 96 / 746 ms          | 25 / 88 / 808 ms | 25 / 94 / 802 ms         |
| wall time (16 cores)   | 4 min 57 s                | 3 min 57 s       | 4 min 58 s               |

Every game finished: no illegal move, crash, stall or capped game. The
rulebook against random is unchanged by this work at 98.8%
(`--pairs 1000 --seed 71`, the PID-377 figure). Against the PID-365
rulebook, before PID-377 landed, the same search won 83.7% on seed 3795.

Development seed 3790 (200 pairs each, against the same rulebook) chose
the budget: K = 50 won 80.8% (p95 47 ms), K = 100 85.0% (p95 92 ms), K =
200 79.8% (p95 193 ms); at 200 pairs a rate is good to about 2.6 points, so
more worlds buy nothing. Search in play alone won 70.3%, search in the
auction alone 64.8%. The veto costs nothing measurable (85.0% with, 84.0%
without on 3790; 81.4% and 81.7% held out), so it stays: most moves remain
ones the rulebook can explain.

Decision times above are per decision, each in one process, with one game
per scheduler. On a single scheduler (`elixir --erl "+S 1:1" -S mix
pidro.selfplay --pairs 20 --seed 3794 --a search --b rulebook`, one game at a
time) search took p50 23 ms, p95 80 ms, max 397 ms, and won 31 of 40. One
core meets the 400 ms p95 bar, so worlds are not spread over processes.

Read the win rate with one caveat: the rollouts play the rulebook for every
seat, so against the rulebook search has an exact model of its opponents.
Against random, a model that is wrong, it still wins 99.8%. People play
neither way, so human play is the test before any table gets it.

What search overrules most is in
[bot-search-disagreements.md](bot-search-disagreements.md), the material
for PID-136. Mostly the auction: the rulebook passes an open auction or an
opponent's 6 with three to five trumps where search makes the contract in
most worlds, and volunteers a 6 on three or four trumps with an unguarded
Five where search makes it too rarely. In play, the rulebook cashes its Ace
on the opening lead from four or five trumps where search leads low.
Seeds 3790–3797 are used; do not report them as unseen.

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

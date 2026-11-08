# Pidro Backend

Multiplayer card game server built with Phoenix 1.8, Elixir, and OTP.

## Required testing policy

Read root `AGENTS.md` and [`docs/testing.md`](../../docs/testing.md). Feature orbs
prove the changed API/channel/UI behavior and a control, then run only affected
files/lines. Never run full `mix test`/`mix precommit`, full gameplay/account/visual
regression or native checks during feature work. For app visuals: one standard phone,
one additional size only for a named layout risk. Full/native coverage is deliberate
release work on Marcel's machine or a release runner; list it as pending, not proven.
Missing focused proof blocks completion claims; browser proof is not native proof.
Every push runs affected tests + smoke; full CI and production deployment are manual
release actions. Do not foreground-watch/poll CI; report run URL/current status.

## Commands

```bash
mix precommit           # RELEASE/MANUAL ONLY: format, compile, all tests, Credo, Dialyzer
mix test                # RELEASE/MANUAL ONLY: all tests
mix test --failed       # Re-run failed tests
mix test path/to/test.exs:42  # Run specific test at line
mix format              # Format code
mix dialyzer            # Type checking
ops/credo-diff          # High-priority lint added since origin/main
```

## Architecture

- **Pure functions over GenServer logic**: Business logic in pure modules, GenServers only coordinate state
- **Single source of truth**: Derive data, don't store duplicates
- **Thin GenServers**: Validation → delegate to pure function → update state → broadcast

## Key Directories

- `lib/pidro_server/games/` - Game engine, room management
- `lib/pidro_server_web/` - Phoenix web layer (controllers, channels)
- `thoughts/` - Plans, research, documentation

## Progressive Disclosure

Read these when relevant:
- `thoughts/AGENTS.md` - Phoenix/Elixir patterns and gotchas
- `thoughts/shared/plans/` - Implementation plans for features
- `thoughts/shared/research/` - Technical research documents

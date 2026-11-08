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
Every push runs affected tests + smoke; successful main push CI auto-deploys its SHA.
Full CI remains manual release coverage. Root working rules apply: one ticket per
thread, one independent review (no repeated review-and-fix rounds), local backend/DB
only for app–backend contract changes, stop/report after about 90 minutes, and finish
the turn after pushing without watching CI. Report run URL/current status truthfully.
An optional GitHub-runner nightly needs a cheap, justified scope; none is configured.

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

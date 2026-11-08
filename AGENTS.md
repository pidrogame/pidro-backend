# Pidro Backend

An Elixir umbrella: the Phoenix server is `apps/pidro_server` (read its
`CLAUDE.md`), the game engine is `apps/pidro_engine` (read its `AGENTS.md`).
Rules belong to the engine; the server only serializes what the engine knows.

## Shipping

- **Prove changed behavior.** Marcel requires: **"I always want the expectations to
  be that the orb needs to provide irrefutable proof that whatever it has built is
  working."** Follow [`docs/testing.md`](docs/testing.md): reproduce the bug, show the
  fix and a nearby control through the real API/channel/engine boundary; run only
  affected test files/lines. **Feature orbs must not run `mix precommit`, bare
  `mix test`, full gameplay/account regression, full visual matrices or native checks.**
  For app proof use one standard phone size, a second only for a named layout risk.
  Full suites/native checks belong to Marcel's machine or deliberate release work.
  Browser proof is not native proof. Missing required focused evidence means
  **implemented; verification incomplete/blocked**; explicitly list release/native
  coverage deferred and never claim release ready without it.
- **Push to `main`.** No PR: a small set of commits, rebased on
  `origin/main`. Report CI's run URL and current result; **do not foreground-wait**
  with watch/poll/sleep loops. Pending is not green/deployed. Fix a reported failure
  caused by the change. No schedules/subscriptions without authorization.
- **Push CI runs affected tests + smoke only**, with `Backend ready` authoritative.
  Manual Backend CI runs the complete `mix precommit` release regression.
- **Production is a deliberate release**, not automatic on push: green manual/full
  Backend CI for the exact candidate, then manually start Deploy, which retains full
  frontend Game/Account guards. Don't trigger release/deployment without authorization.
- **Roll back** with `mise exec -- scripts/rollback` (previous version) or
  `mise exec -- scripts/rollback <sha>`; add `--dry-run` to look first.
  [docs/deploy.md](docs/deploy.md) says when to roll back and when to fix
  forward.

## Load-bearing paths

A diff that touches any of these gets an independent review before the push
(`coderabbit review --plain` or `codex review` if available, otherwise a
separate skeptical pass over the whole diff). Answer every finding.

- **Engine rules, scoring and turn order:** `apps/pidro_engine/lib/pidro/core/`,
  `apps/pidro_engine/lib/pidro/game/`, `apps/pidro_engine/lib/pidro/finnish/`,
  `apps/pidro_engine/lib/pidro/rules/`, `apps/pidro_engine/lib/pidro/rules.ex`
- **Auth, sessions and Classic claims:** `apps/pidro_server/lib/pidro_server/accounts/`,
  `apps/pidro_server/lib/pidro_server_web/plugs/authenticate.ex`,
  `apps/pidro_server/lib/pidro_server_web/controllers/api/auth_controller.ex`,
  `apps/pidro_server/lib/pidro_server_web/controllers/api/classic_claim_controller.ex`
- **IAP and entitlements:** none exist in this repo yet; the code that adds
  them is load-bearing from its first commit.
- **Database migrations:** `apps/pidro_server/priv/repo/migrations/`
- **Seat passwords:** `apps/pidro_server/lib/pidro_server/games/room/config.ex`,
  `apps/pidro_server/lib/pidro_server/games/room/positions.ex`,
  `apps/pidro_server/lib/pidro_server/games/room_manager.ex`
- **The socket:** `apps/pidro_server/lib/pidro_server_web/channels/`

# Pidro Backend

An Elixir umbrella: the Phoenix server is `apps/pidro_server` (read its
`CLAUDE.md`), the game engine is `apps/pidro_engine` (read its `AGENTS.md`).
Rules belong to the engine; the server only serializes what the engine knows.

## Orb working rules (all tickets)

- **One ticket per thread.** Do not reuse an old thread for a new task.
- **Implement and prove it:** affected tests plus direct evidence of the changed
  behavior and a nearby control. Green tests alone are not proof.
- **One independent review**, not repeated review-and-fix rounds. Address findings,
  rerun affected proof, then ship; do not request another routine review cycle.
- **Start the local backend/DB only for app–backend contract changes**, not for
  copy/layout, client-only logic, docs or CI work. Exercise pure engine changes
  directly without starting Phoenix/DB; disclose any unexercised boundary.
- **About 90 minutes per ticket in the orb:** if exceeded, stop and report whether
  scope is too large, a test is flaky, or an external dependency is blocking progress.
  Include evidence, remaining work and a proposed split/unblock; do not grind on.
- **After pushing, finish the turn.** Report commits, CI URLs and known status;
  don't watch CI in the foreground. A later reported failure is a follow-up.
- Full matrices, full journeys and native checks belong at release, or an optional
  justified nightly on GitHub runners, never routine feature-orb work. No nightly
  is configured; don't add one without a cheap, justified scope and authorization.

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
- **Production deploys automatically** when push Backend CI passes on `main`, using
  that exact SHA. Manual/full CI does not deploy; full Game/Account/native regression
  remains separate release coverage, not a prerequisite on every push. Backup,
  migration, health, production smoke and deployed-version checks remain mandatory.
- **Roll back** with `mise exec -- scripts/rollback` (previous version) or
  `mise exec -- scripts/rollback <sha>`; add `--dry-run` to look first.
  [docs/deploy.md](docs/deploy.md) says when to roll back and when to fix
  forward.

## Load-bearing paths

A diff that touches any of these gets one independent review before the push
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

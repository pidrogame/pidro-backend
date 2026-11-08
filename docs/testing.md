# Testing and proof contract

Marcel's requirement is non-negotiable:

> I always want the expectations to be that the orb needs to provide irrefutable
> proof that whatever it has built is working.

## Feature work: changed behavior, affected checks only

Every orb must exercise the changed contract itself and show evidence, not simply
report green tests. Before editing, name the entry point, likely wrong behavior,
focused checks and expected observation. For a bug reproduce the old failure, then
rerun identical data/timing after the fix, with a nearby unchanged control and the
relevant denied/error/recovery case. Use real API/channel/engine output, state and
correlated logs; mocking the changed boundary does not prove it.

Run specific ExUnit files/lines; static compile/format/lint as relevant. **Do not run
`mix precommit`, bare `mix test`, full gameplay/account regression, full screenshot
matrices or native checks in feature orbs.** Shared logic needs its affected consumers,
not an automatic whole-repository sweep. Never use a fresh-cache `--stale` run as a
shortcut: it can run everything. Preserve critical assertions and public contracts.

If inspecting the app, use one standard phone size (normally 390×844), and at most
one other size for a named layout risk, not every viewport and screen. Inspect media
and report observable state/geometry alongside it. Freeze Metro's served source:
no edits/rebases/checkouts/installs/cache clears/restarts during capture. Concurrent
editing requires a separate frozen worktree/server/port. Invalidate interrupted or
stale-bundle evidence and rerun just that selection, not the full matrix.

## Risk triggers

| Risk | Required focused feature proof | Release coverage left to Marcel/release owner |
| --- | --- | --- |
| Rules/scoring/state | Exact engine actions and independently expected state/score, boundary/error/control; affected unit/property tests using valid generators. | Entire engine/property/integration regression. |
| API/auth/claims/permissions/persistence | Real request/channel and DB state, allowed + denied + retry/reload control. Isolated test data, never production writes. | Full account, expiry and gameplay journeys against exact backend SHA. |
| Socket/readiness/reconnect/timing | Force the failing delay/order; record old/new event order and state; targeted repetitions and reset/reconnect controls. | Full multiplayer/rematch/seat-replacement/lifecycle journeys; not repeated full games to recreate one race. |
| Client copy/layout/shared UI | Actual affected states and a nearby control at one phone size; second size only for wrapping/landscape/tablet-specific risk; DOM/geometry + inspected captures. | Full sizes/locales/text-scale visual matrix and baseline reconciliation. |
| Native keyboard/modal/insets/gestures/storage/SDK/lifecycle/GPU | Strongest reachable focused browser/logic check; explicitly disclose native boundary not exercised. | Appropriate iOS simulator/device/build on Marcel's machine or deliberate release runner; hardware/provider/performance risks require a suitable device. |
| Tooling/CI/guidance | Real selector/gate commands with passing, missing and deliberately failing inputs; realistic policy scenarios. YAML parsing alone is insufficient. | Full-run inventory retained; full regression deliberately executed for a release. |
| Migrations/dependencies/runtime/container | Focused compatibility/rollback/packaging checks and explicit limits; review load-bearing changes. | Complete `mix precommit`, candidate container/config checks and release integration/native build as applicable. |

Browser Playwright/Expo-web, synthetic insets and provider stand-ins are **not native
iOS proof**. Protocol gameplay proves server/protocol integration, not touch UI.
Full visual/game/account and native checks move to release time, on Marcel's machine
or by deliberate release execution; do not replace missing native evidence with a
larger browser matrix. See the frontend's `docs/testing.md` and mobile device flows.

## Permanent CI and release split

- Push/PR **Backend CI** selects explicit affected ExUnit files plus two smoke files
  (card rules and error rendering). It follows module consumers/aliases transitively,
  changed tests/support and referenced assets. Unknown change ranges use smoke with
  an explicit limitation, never full-suite fallback. Static impact is conservative,
  not exhaustive for dynamic calls/configuration: authors still prove changed behavior
  and select relevant regressions locally. Last successful main push is the base,
  so cancellation/red runs do not lose changes. Selector CLI regression runs in CI.
- Compile/format/audit/diff-scoped lint, container build and deployment configuration
  checks remain. **Backend ready** requires every prerequisite to succeed; missing,
  skipped, failed or cancelled selected jobs cannot silently pass.
- Manually dispatch **Backend CI** for complete `mix precommit` (all tests, audit,
  format, compile, Credo and Dialyzer): **Backend ready (full)**. It does not deploy.
- Production is a deliberate release: manually start **Deploy** for a main candidate
  with a successful manual/full Backend CI on that exact SHA. Full frontend Game and
  Account journeys still guard deployment, then backup/migration/health/smoke/version
  checks run. Feature pushes no longer start those full journeys or auto-deploy.
  This preserves production protection rather than replacing full guards with smoke.
- Do not foreground-wait for CI: no watch/poll/sleep loops. Report commit, run URL
  and current state; pending is not green/deployed. Fix a reported failure you caused.
  Do not create schedules/subscriptions or trigger release/production without approval.

From the umbrella root, an example focused command:

```bash
mix test apps/pidro_engine/test/unit/card_test.exs:42
python3 scripts/test-ci-affected.py
python3 scripts/ci-affected.py <base-sha> <head-sha>
```

Choose the actual changed file/line, not the example for every task. Keep valid
evidence for unchanged code; repeat only affected checks after fixes. Do not weaken
assertions, add blanket sleeps/retries, or treat a retry pass as erasing a failure.

## Handoff

State the changed claim/platform, before → after/control observations, exact command
and decisive output/exit status, candidate/backend identity, inspected media and
mocked boundaries. Separate local, committed, pushed, CI and deployed states.
**Missing required focused proof: implemented; verification incomplete/blocked.**
List full regression/native evidence deliberately deferred to Marcel/release owner;
say “focused proof passed; release/native verification pending,” not “release ready.”
Guidance audits do not prove agent compliance; disclose when fresh-agent old/new
evaluations were not run. Full suites belong to releases, not every feature thread.

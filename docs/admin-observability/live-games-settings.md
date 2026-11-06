# Live games overview and game settings

Implementation branch: `admin-ops/live-games-settings`. Review-ready, not integrated or deployed.
Evidence lives in [the implementation thread](https://ampcode.com/threads/T-01a163d1-2c54-75b6-9743-784295c50c38).

## Behavior and cost

- `/admin/games` shows actual seated public names/available avatars, teams, score,
  phase, turn, last action/time, seat connection state, Watch links and copyable IDs.
  Developer creation/deletion controls remain explicit; there is no automatic intervention.
- `/admin/game-settings` owns the same nine pacing controls, validation, runtime
  save/reset and preview, using the existing `PacingSettings` source of truth.
  Both routes retain existing admin/password-change authentication.
- Each engine process synchronously writes a fixed compact projection into its own
  existing GameRegistry entry. It retains phase, turn, trick/hand numbers, cumulative
  scores, pace, event **type only**, activity time, and a `table` of what everyone
  seated can see: cards on the felt (current trick, or the trick just taken),
  trump, bids, dealer, hand points, card counts per seat, cold seats and the
  winner. No card still in a hand, action arguments, user records or diagnostic
  payloads are kept, and nothing is added to any broadcast.
- `/admin/games` draws each table as a small felt (2026-11-05 redesign): seats with
  turn light, dealer/bot/bid badges and card counts; the trick as it lands; scores
  beside the pair of player names; a seat click opens a player or bot preview
  (level, games, win rate, quits, joined, copy ID, profile link).
- No separate cache process can restart and lose idle summaries. Registry ownership
  fences old rematches and removes projections when games stop. Existing Registry
  consumers ignore metadata; their PID lookup contract is unchanged.
- Only connected LiveViews subscribe to existing lobby lifecycle PubSub. Each has
  one self-scheduled sample, scheduled **after** processing, every 750ms. Actions
  overwrite the latest projection rather than enqueue overview notifications/tasks.
  Existing hand/score-only lobby updates are ignored until sampling; actual lifecycle
  and membership changes are shown immediately. Intermediate action states may be
  intentionally coalesced. The existing lobby's lifecycle message volume is unchanged.
- Sampling costs O(number of rooms) small Registry reads per connected overview,
  with no engine calls or SQL. A changed seated-ID set uses `Auth.get_users_map`:
  at most two bulk SQL queries (users/avatar join and badges), never per-seat queries.
  Bot/non-UUID-only rosters need no SQL. Public profile projection drops other fields.
- Activity age is informational: no inactivity threshold or red stuck classification.
  Own-pace hand completion reads “Waiting for Continue.” Only missing game processes
  or reconnecting/reserved-substitute seats contribute issues. Waiting includes ready.
  A changed-row animation lasts 650ms; reduced motion disables it.

## Executed verification

From umbrella root, using the orb's configured toolchain:

```sh
mise exec -- mix precommit
```

Final run exited 0: engine **911 passed** (79 doctests, 169 properties, 663 tests),
1 skipped; server **1970 passed** (67 doctests, 1903 tests), 1 skipped.
Formatting/compilation passed, diff-scoped Credo added no issues, Dialyzer passed
(56 existing suppressed warnings). Raw logs are deliberately not published because
the existing test suite logs synthetic authentication data.

Coverage includes two real engine processes, action/timer phase and turn updates,
fixed card-free projection keys, lifecycle finish/rematch/closure, joins/leaves,
public-name resolution outside the most recent 20 users, own-pace holds and filters,
and authenticated/anonymous/player/forced-password route access. Settings tests
assert all actual runtime values after save/reload/reset and invalid no-partial-write
behavior. A separate received-ready-room projection regression checks Waiting counts
and filtering; that projection test is not claimed as engine end-to-end evidence.

Independent review found three issues, all resolved: idle summary loss after cache
restart, hand-derived lobby events bypassing the sampler, and Ready/Waiting filter
inconsistency. Final skeptical inspection also checked Registry lookup compatibility,
observer defaults, projection privacy and the unchanged admin route boundary.

Coordinator review additionally found creation cleanup could crash when BotManager
was unavailable. Cleanup is now best-effort for both custom and preset creation;
admin warnings are actually rendered (the shared public flash group only supported
info/error). A real LiveView form test with the manager name temporarily unregistered
asserts the saved room, visible warning, live process and a subsequent filter change.
All three bot presets preserve the warning across normal navigation. Removing just
the cleanup guard makes the custom-create test fail with the reported `stop_all_bots`
exit; restoring it passes. The two page suites pass **23 tests**. The same form test
also covers a 16-byte synthetic developer host: only database-dumpable UUIDs enter
the bulk profile query, avoiding an Ecto raw-UUID cast/SQL dump mismatch. Developer
controls stay expanded when their create form opens.

### Real browser and runtime evidence

Phoenix ran as supervised orb service `admin-overview`, with real PostgreSQL,
actual synthetic admin login and development login bypass disabled. Two tables
were created through RoomManager, with real human channel registration/readiness.
Bots on the own-pace table were deliberately paused to make actions controllable.
Legal actions drove that table from dealer selection through a hand to an own-pace
hold, while the other table remained unchanged. No fabricated browser score state.

- Connected desktop browser: 1280×900, DPR 2. Video shows one table's turn/action
  update without refresh, the quiet table unchanged, settings navigation and save
  of bot base delay 2400ms. Reset is **not** visible in the clip; reset is covered
  by runtime assertions, tests and the desktop reset confirmation screenshot.
- A subsequent real bid probe on the other table returned `:ok`, action `bid_made`,
  turn east → south, activity advanced, control summary unchanged. A temporary
  `[:pidro_server, :repo, :query]` telemetry counter measured **0 queries** through
  that action plus 1600ms of connected overview sampling.
- Browser save/reset was followed by a runtime RPC comparison of
  `PacingSettings.current_values()` and `default_values()`: **true for all fields**.
- Phone: Playwright Chromium with full Pixel 7 touch descriptor, DPR 2, 412 CSS px.
  `(pointer: coarse)` verified true; document width and viewport both 412 on both
  pages, all nine settings inputs present. This is emulation, not a native device.
  Continue-filter selection and navigation were exercised with real browser input.
- Reduced-motion emulation verified media preference true and computed changed-row
  animation name `none`. All listed screenshots and the clip were inspected.
- A real desktop browser repeated custom creation with the actual manager's name
  temporarily unregistered. It created room UF6C, displayed the warning, stayed
  `.phx-connected`, then selected Waiting and displayed the saved room. The manager
  was restored in `finally`. This uses real Phoenix/RoomManager, not a mocked handler.

Artifacts under `.amp/in/artifacts/` in the implementation thread (downloadable
with Amp's thread-file tools; not committed as source binaries):

| File | Evidence |
| --- | --- |
| `live-games-desktop-before.png` | Two running games, initial state |
| `live-games-desktop-after.png` | One game bidding/turn changed; control unchanged |
| `live-games-desktop-own-pace.png` | Actual -9/12 hand score, normal Continue hold |
| `live-games-phone.png` | Touch-emulated narrow overview, both tables |
| `live-games-phone-filtered.png` | Continue filter, one of two tables |
| `game-settings-desktop.png` | All controls and reset confirmation |
| `game-settings-phone.png` | Narrow settings, all nine controls |
| `live-games-bot-unavailable.png` | Real failure path, saved room and visible warning |
| `admin-overview-settings.mp4` / `.loop.webp` | Real moving-pointer realtime/save clip |

## Compatibility and limitations

No migration, dependency, native-client protocol or game-rule/scoring change.
The optional engine observer defaults to absent for standalone consumers. Summaries
are node-local like the existing game Registry/RoomManager architecture; they are
not a new distributed or historical monitoring store. Pacing remains runtime
Application configuration, not disk persistence, exactly as before. No network or
database work was added to the game-action path. Existing seat persona helpers are
used; no second bot registry was introduced. No PR, main push or deployment was made.

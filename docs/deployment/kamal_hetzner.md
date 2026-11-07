# Kamal on Hetzner

This repo is pinned to Erlang 29.0.3, Elixir 1.20.2, Ruby 4.0.5,
Kamal 2.12.0, Phoenix 1.8.9, Phoenix LiveView 1.2.8, and PostgreSQL
18.4. The Mix lockfile pins the remaining Hex dependencies, and the production
container base images are pinned by digest.

The Hetzner host does not need Elixir installed. Kamal deploys the release image built from [Dockerfile](../../Dockerfile), so production runs the same OTP/Elixir pair pinned locally in [.tool-versions](../../.tool-versions).

## First-time setup

1. Run `mise install`, `bundle install`, and `mix deps.get`.
2. Create a GHCR token with package read/write access.
3. Copy [.kamal/secrets-common.example](../../.kamal/secrets-common.example) to `.kamal/secrets-common` and fill in real values.
4. Run `just bootstrap` to install Docker on the server and open `22`, `80`, and `443`.
5. Create Route53 records for `app.pidro.online` before the first TLS deploy.
6. Run `just setup` to boot Postgres, push secrets, and deploy the app.
7. Run `just install-backup-timer` once to install the daily database backup.
8. Run `just deploy`. Deploys automatically back up the database, run pending
   migrations against the new image before it boots, and smoke-test production.

## Secrets

Required secrets:

- `KAMAL_REGISTRY_PASSWORD`
- `SECRET_KEY_BASE`
- `POSTGRES_PASSWORD`
- `CLASSIC_API_URL`
- `CLASSIC_CLAIM_SECRET`
- `FB_APP_SECRET`

## DNS

Create these records in the `pidro.online` hosted zone:

- `A` record: `app.pidro.online` -> `95.217.3.224`
- optional `AAAA` record: `app.pidro.online` -> `2a01:4f9:c013:e90d::1`

Use a low TTL like `300` for the first cutover.

## Notes

- [config/deploy.yml](../../config/deploy.yml) is set to `app.pidro.online` with Kamal-managed Let's Encrypt TLS.
- Kamal’s proxy health check hits `/up`, which also verifies database connectivity.
- PostgreSQL 18.4 runs as a Kamal accessory named `postgres`, persists its
  versioned data directory in the `postgres18-data` volume, and is available
  only on the internal Docker network and host loopback interface.
- Builds are configured to run on the Hetzner host as a remote `amd64` builder, which avoids local Apple Silicon emulation issues.
- Production ops routes require an individual admin session. The deployment config
  sets `ADMIN_EMAIL` to `m.fahle@gmail.com`; run `just seed-admin` after migrations
  and securely retain the generated temporary password shown by the command.

## Proxy headers and rate limiting

The API rate limiter (`PidroServerWeb.Plugs.RateLimit`) keys most policies by
client address, so the release must learn the real client behind kamal-proxy.

- kamal-proxy terminates TLS and forwards to the container over the Docker
  bridge network, so Phoenix sees the proxy's private address as the TCP peer.
- [config/deploy.yml](../../config/deploy.yml) keeps kamal-proxy's
  `forward_headers` at its default (off with TLS). kamal-proxy then strips any
  client-supplied `X-Forwarded-*` headers and writes exactly one
  `X-Forwarded-For` value: the true peer. Do not add a `forward_headers` key;
  the `deployment-config` CI job fails if one appears.
- `PidroServerWeb.Plugs.TrustedProxy`, the first plug in the endpoint, honours
  `X-Forwarded-For` and `X-Forwarded-Proto` only when `TRUST_PROXY_HEADERS` is
  true (the production default; false in dev and test) and the TCP peer is a
  loopback, RFC 1918, CGNAT, IPv6 loopback, ULA or link-local address. It takes
  the rightmost `X-Forwarded-For` value, so even if `forward_headers` were ever
  enabled and client-supplied values were kept, the proxy-appended peer would
  still win.
- `TRUST_PROXY_HEADERS: "false"` under `env.clear` makes the limiter key on the
  TCP peer instead; every client then shares the proxy's bucket, so use it only
  to diagnose a limiter problem.
- Limits are tuned with `RATE_LIMIT_<POLICY>_LIMIT` and
  `RATE_LIMIT_<POLICY>_SCALE_MS`, where `<POLICY>` is one of `LOGIN`,
  `REGISTER`, `PASSWORD_RESET`, `PASSWORD_RESET_IDENTIFIER`,
  `PASSWORD_RESET_CONFIRM`, `ROOM_CREATE`, `ROOM_LOOKUP`, `ROOM_JOIN`,
  `INVITE_MINT`, `INVITE_PREVIEW`, `INVITE_CAPTURE`,
  `INVITE_CAPTURE_CODE`, `INVITE_DEFERRED`, `INVITE_DEFERRED_INSTALL`,
  `INVITE_REDEEM`, `GUEST_CREATE`,
  `GUEST_CREATE_DAILY`, `GUEST_CREATE_INSTALL` or `AUTH_UPGRADE`, for example
  `RATE_LIMIT_LOGIN_LIMIT: "20"`. There is no off switch: raise a limit and
  redeploy. Never roll back a release to fix limiter behaviour.
- Limits are per node and per fixed window; counters reset on restart.
- The invite and guest policies (production defaults in `config/config.exs`):
  `INVITE_MINT` 10/min per user, `INVITE_PREVIEW` 60/min per IP,
  `INVITE_CAPTURE` 20/30min per IP, `INVITE_CAPTURE_CODE` 200/30min per
  hashed invite code, `INVITE_DEFERRED` 5/30min per IP,
  `INVITE_DEFERRED_INSTALL` 2/30min per hashed `install_id`,
  `INVITE_REDEEM` 10/min per user, `ROOM_JOIN` 30/min per user,
  `GUEST_CREATE` 10/hour per IP, `GUEST_CREATE_DAILY` 40/day per IP,
  `GUEST_CREATE_INSTALL` 3/hour per hashed `install_id`, `AUTH_UPGRADE` 10 per
  10 minutes per IP.
- `GUEST_CREATE` is deliberately generous: a QR-code party behind one NAT is the
  designed case, so the first symptom of a bad limit is real friends being
  turned away, not abuse. A request without an `install_id` skips only
  `GUEST_CREATE_INSTALL`; the two IP-keyed guest policies still apply.
- Keep `AUTH_UPGRADE` the same size as `REGISTER`: a looser upgrade limit turns
  the endpoint into an email-existence oracle.
- `GET /api/v1/invites/:code` and `POST /api/v1/auth/guest` are the two new
  unauthenticated routes, so `INVITE_PREVIEW` and the two IP-keyed
  `GUEST_CREATE` policies are the ones to watch when a link is shared widely.

### One-time production check

`ops/smoke-production` cannot see the derived client address, so verify the
header contract once after the first deploy that carries the limiter:

1. Add `RATE_LIMIT_LOGIN_LIMIT: "1"` under `env.clear` in
   [config/deploy.yml](../../config/deploy.yml) and run `just deploy`.
2. From your own network, `POST https://app.pidro.online/api/v1/auth/login`
   twice within one minute (any credentials). The second response must be
   `429` with a `Retry-After` header.
3. From a second network (a phone on mobile data), send the same request
   once. It must not be `429` (expect `401` for bad credentials). A `429` here
   means the limiter keyed on the proxy address: check that
   `TRUST_PROXY_HEADERS` is not `false` and that `forward_headers` has not been
   enabled.
4. Remove the override and run `just deploy` again.

## Invites, guests and waiting rooms

These variables also go under `env.clear` in
[config/deploy.yml](../../config/deploy.yml). All are optional; each replaces
only the key it names, and defaults live in `config/config.exs`.

- `DEFERRED_INVITES_ENABLED` is `false` by default. Deploy and verify the
  canonical privacy-policy disclosure before setting it to `true`. Deferred
  invite hints live only in the named `PidroServer.Invites.DeferredMatcher`
  process and are removed on consumption, restart, or after 30 minutes. Disable
  the flag and redeploy to stop new capture and resolution immediately.
- Deferred matching requires exactly one Phoenix application replica. The
  checked-in `servers.web` list deliberately contains one host. Before adding a
  second app replica, replace the node-local matcher with a Pidro-owned shared
  ephemeral store or cluster-wide single owner that preserves the 30-minute
  hard-deletion contract. A rolling deploy can evict hints early; manual invite
  code entry is the recovery path.

- `INVITE_LINK_BASE_URL` (default `https://www.pidro.online/j`) is the base of
  every
  invite link: `PidroServer.Invites.url/1` renders `<base>/<CODE>` and
  `share_text` repeats the dashed code. It must point at the host serving the
  invite landing page, which is also the host whose
  `/.well-known/apple-app-site-association` `AASA_PATHS` must cover `/j/*` and
  the player share links `/play/*` (`PidroServer.Invites.play_url/1`). If
  the landing host moves, change this **and** the AASA paths in the same deploy;
  links already in the wild keep pointing at the old host until they expire
  (24 hours).
- `GUEST_REAPER_ENABLED` (default `true`; `true`/`TRUE`/`1`/`yes`/`YES` enable,
  anything else disables), `GUEST_REAPER_INTERVAL_MS` (default `3600000`) and
  `GUEST_REAPER_MAX_IDLE_DAYS` (default `30`) drive the idle-guest sweep. It
  deletes guest accounts whose `last_seen_at` (or `inserted_at` when nil) is
  older than the threshold, using the same irreversible recipe as
  `DELETE /api/v1/auth/me`: one database transaction revokes hosted invites
  and deletes `player_profiles`, `player_achievements`, `invite_redemptions`,
  `invite_events` and the `users` row; room-seat cleanup and disconnect happen
  only after commit. The transaction locks and reloads the account and proceeds
  only if it is still a guest, so a concurrently completed upgrade is never
  reaped. Registered accounts are never touched. Both numeric
  values must be positive integers or application boot fails. Set
  `GUEST_REAPER_ENABLED: "false"` and redeploy before investigating anything
  guest-related; there is no undo.
- `LIFECYCLE_INVITED_WAITING_TTL_MS` (default `7200000`, two hours) is how long
  a `waiting` room with a live invite may sit idle with nobody connected before
  the sweep closes it; without a live invite that sweep uses its fixed 5-minute
  grace period. This is the knob for "the host left the app to paste the link
  and came back to a dead table": raise it, redeploy, and the running rooms pick
  up the new value on the next sweep.

The invite cutover is deliberately backend-first: deploy Phoenix, verify
`https://app.pidro.online/j/<OPEN_CODE>`, then deploy the marketing-site rewrites
for `/j/*`, both AASA paths and `/.well-known/*`. The public canonical host is
`https://www.pidro.online`; the apex host redirects and must not be used for new
Universal Links. After both deploys, run:

```bash
PIDRO_PUBLIC_URL=https://www.pidro.online PIDRO_INVITE_CODE=<OPEN_CODE> ops/smoke-production
```

The public-host checks fail on redirects, unexpected cookies, incorrect
association signing data or caching, invite metadata drift, or a broken
iOS/Android/desktop render branch. `GET /j/:code` uses its own per-invite-code
limit because the origin sees a Vercel edge address; it does not share the
mobile API preview bucket.

Phase 4 has a separate privacy-first rollout: deploy the marketing privacy
addendum while `DEFERRED_INVITES_ENABLED` remains `false`, deploy Phoenix, then
enable the flag and verify direct browser-to-`app.pidro.online` capture before
shipping the native build. Roll back the mobile bootstrap first, then disable
the flag; remove the disclosure only after the data path is no longer shipped.

Universal Link and App Link verification is cached by Apple and Android. After
cutover, verify the public AASA response first, allow for Apple CDN propagation,
then open a fresh `/j/<OPEN_CODE>` link from Notes or Messages on a physical
iPhone. On Android, verify the host association with:

```bash
adb shell pm verify-app-links --re-verify com.oneapps.pidro
adb shell pm get-app-links com.oneapps.pidro
```

The `www.pidro.online` host must report as verified before the mobile release is
promoted.

## Release flow

Run the local quality gate and deploy only from a clean commit:

```bash
just quality
just deploy
```

The Kamal hooks enforce the release order:

1. Refuse to build from a dirty worktree.
2. Create and validate a PostgreSQL custom-format backup.
3. Run all pending Ecto migrations using the exact image being deployed.
4. Boot the new container and wait for `/up` to verify database connectivity.
5. Verify TLS, API authentication, CORS, disabled developer routes, and the
   WebSocket endpoint.

Use `just rollback <git-sha>` to restore a retained application image. Database
migrations are not automatically reversed; restore the database only when a
rollback is incompatible with the migrated schema.

### Token payload rollback

Auth tokens carry a versioned payload (`%{id, v}`) since the invite-prerequisites
release. That change is roll-forward only: a release built before it cannot
verify any token minted since the deploy and would reject every logged-in
user, so `just rollback` must never cross that release.

- Limiter problems are corrected by environment changes and a redeploy, never
  by rolling back: raise `RATE_LIMIT_<POLICY>_LIMIT` (or `_SCALE_MS`), or set
  `TRUST_PROXY_HEADERS: "false"` under `env.clear` while diagnosing.
- If the versioned payload itself must be withdrawn, rotate `@signing_salt` in
  `apps/pidro_server/lib/pidro_server/accounts/token.ex` and deploy forward;
  every token dies and users log in again.
- Legacy bare-id tokens are accepted until 30 days after the production deploy
  of that release, not before 2026-10-02; whoever deploys writes the literal
  date into the legacy clause in `token.ex`.

### Settled hands rollback

Since PID-366 a game that settles a hand keeps a `{:hand_settled, …}` event and
a `settled` key in `last_hand`. A release built before it cannot decode those
atoms, so a rollback across PID-366 loses every live table whose game has
settled a hand (it restores as `room_not_found`). Fix forward instead; roll
back across it only when losing those tables is the lesser harm.

## Database backups

Backups are stored on the server in `/var/backups/pidro` as PostgreSQL custom
format dumps with SHA-256 checksums. Every dump is validated with
`pg_restore --list` before it is accepted. The systemd timer runs daily at
02:00 UTC with up to one hour of jitter, retains 30 days, and catches up after a
server outage.

Useful commands:

```bash
just backup
just install-backup-timer
ssh root@95.217.3.224 'systemctl list-timers pidro-backup.timer'
ssh root@95.217.3.224 'ls -lh /var/backups/pidro'
```

To verify a restore without touching production, restore into a disposable
database on a non-production PostgreSQL instance:

```bash
createdb pidro_restore_test
pg_restore --clean --if-exists --no-owner --dbname pidro_restore_test pidro-YYYYMMDDTHHMMSSZ.dump
dropdb pidro_restore_test
```

These host-local backups protect against bad migrations and accidental data
changes. Enable Hetzner server backups or copy the dumps to separate object
storage for host-level disaster recovery.

## PostgreSQL major upgrades

Never point a newer PostgreSQL major image at an older major's data volume.
Create a verified custom-format dump, stop application writes, boot the new
major against a new volume, restore the dump, verify the schema and row counts,
and only then resume traffic. Keep the stopped old container and volume until
the new database has passed production smoke checks and a scheduled backup.

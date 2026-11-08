# Deploying

Successful main push CI **deploys automatically**. Full regression runs separately
for a release or manual dispatch, never on each push.
Nobody runs `just deploy` as a feature-work shortcut. See [testing](testing.md).

## How a commit reaches production

1. A push to `main` runs **Backend CI** (`.github/workflows/ci.yml`): affected ExUnit
   tests plus two smoke files, static quality, container and deployment-config checks.
   `Backend ready` is authoritative. Report the URL/current state without foreground
   CI waits; pending is not deployed.
2. **Deploy** (`.github/workflows/deploy.yml`) receives the completed Backend CI run
   automatically. Only a successful **push** on this repository's `main` qualifies;
   failed/cancelled runs, PRs, other branches/repositories and manual/full runs cannot
   deploy. It checks out the triggering run's exact SHA, never a moving `main` ref.
3. **Deploy production** runs `kamal deploy`. Hooks back up the database, migrate
   the new image, wait for `/up`, and run `ops/smoke-production`. The final check
   requires `kamal app version` to match the triggering SHA and `/up` to answer 200.
   A deploy failure is red; Kamal keeps the previous container when the new one
   never becomes healthy. Missing deploy secrets are reported as skipped, not proof
   of a deployment: inspect the summary and version/health check, not just green CI.

Deploys are serialized: a newer queued deploy can replace one waiting, but an active
deploy is never cancelled. After pushing, report the known status and finish the
turn; do not wait in the foreground for CI/deployment.

## Separate release regression

Manually run **Backend CI** on the release candidate for complete `mix precommit`
and **Backend ready (full)**. This does not deploy. In the frontend repository,
Actions → **Frontend CI** → **Run workflow** (`full=true`) runs full Game/Account
journeys and visual regression. Its **Resolve integration backend** summary records
the backend `main` SHA resolved for that run: require it to match the release
candidate. It cannot select an arbitrary older backend SHA; the journey workflows
are reusable (`workflow_call`), not directly manually dispatchable. Collect the
risk-triggered native proof too. These remain release obligations, not per-push
deployment gates. No nightly is configured; a GitHub-runner nightly is only an
option if a cheap scope can be justified.

## Native store notice

Look at **[Store builds](https://app.pidro.online/admin/store-builds)** before
and after every store release. It compares TestFlight's external **Friends**
group and Play's **open testing** (`beta`) track with the effective News
minimums and distinct players per version over the last seven days. Internal
TestFlight builds do not reach players; a Play production draft is information,
not a beta release warning. The page cannot see EAS builds not yet uploaded.
Apple checks run every ten minutes or with **Refresh**. Google Play is checked
only by its **Refresh** button on this page or in the News editor's hint—not
at startup, on page load, or on a timer. Errors retain the last good snapshot
and its timestamp. The cache is node-local and resets on deployment/restart.
Play tracks do not expose upload/release dates.

**New app-update post** fills both platforms from their live store builds:
the version and its build (App Store Connect build number, Play version code).
Review both values before publishing: that post owns both minimums, including
empty ones. The News editor warns, without blocking, when a version exceeds
the live build. See the frontend's `docs/store-builds.md` for the release steps.

When a store build is live, publish an **App update** post in `/admin/news`.
The post owns a version and a build per platform. Set **Android: show below
version** and **iPhone: show below version** to the live versions (for example
`3.3.0`), and **and below version code** / **and below build** to the live
build (for example Android `12`, iPhone `15`). `3.3.0` build `15` nudges
installs below 3.3.0, and 3.3.0 installs below build 15. Without a build, only
installs below the version are nudged; apps too old to send a build are always
compared by version only. A build needs its version. The game channel already
records builds (Store builds counts them); the News pop-up and the lobby reply
only compare them once the app sends `app_build` to `/news` and reads
`minimum_native_builds` (PID-398), so set a build when that app is out.
Leave a platform empty until its build is live: empty means nobody on that
platform. The newest published app-update
post supplies both minimums immediately, even with **Show as pop-up** off.
Drafts do not change the minimums. Unpublishing restores the previous published
update's minimums, or the environment fallback if none remains.

`MINIMUM_NATIVE_*` in `config/deploy.yml` is now **only the fallback when no
published app-update post exists**, and holds a version only. Store destinations remain in `env.clear`;
the next automatic main deploy applies changes to those URLs:

| Platform | Minimum (empty disables notice) | Store URL |
| --- | --- | --- |
| Android | `MINIMUM_NATIVE_ANDROID` | `NATIVE_STORE_URL_ANDROID` — `https://play.google.com/store/apps/details?id=com.oneapps.pidro.beta` |
| iOS | `MINIMUM_NATIVE_IOS` | `NATIVE_STORE_URL_IOS` — `https://testflight.apple.com/join/2JR95b65` |

An empty URL also disables the notice; an unset URL uses the beta default above.
At public launch, replace the beta/TestFlight URLs with the public store listings.

These same URLs drive invite/play page downloads and email `app_store_url` /
`play_store_url` placeholders (including studio previews). Missing URLs hide page
download links; email templates requiring a missing URL report a missing variable
instead of reusing a stale destination. Android invite/friend install referrers
are appended to the configured destination.

The lobby join reply keeps `minimum_native_versions` and `native_store_urls`,
both maps keyed by `android`/`ios`. `minimum_native_builds` (PID-399) sits
beside them, for example `{"android": "12", "ios": "15"}`: the build of that
platform's minimum version, only for platforms whose post sets one. An app
below the version, or on the same version with a lower build, is below the
minimum. The app requires both entries for its platform
and opens only the supplied URL. `native_update_popup` is true when the newest
published app-update post has **Show as pop-up** on. New apps then suppress the
minimum-version fallback card: a seen pop-up must not reappear as that fallback.
False (or absent on an older server) preserves the fallback. Old apps ignore
the additive fields and keep their existing store notice.

### News pop-up contract (PID-363)

Authenticated `GET /api/v1/news?locale=sv&platform=android&app_version=3.3.0&app_build=11`
returns `data.posts` (latest 30), `data.unread`, and `data.popup` (always present,
a localized post or `null`). `locale` is `en` or `sv`, `platform` is `android`
or `ios`, `app_version` is the installed native version and `app_build` its
native build (iOS build number, Android version code; optional). Missing/invalid
platform or version excludes app-update pop-ups, not general News pop-ups.

Posts and pop-ups have `id`, `title`, `body`, `published_at`, `eyebrow`,
`image_url`, `button_label`, `button_url`, `show_as_popup`, `app_update`,
`show_below_android`, `show_below_ios`, `show_below_android_build` and
`show_below_ios_build`. Optional fields are null. Swedish
falls back to English per field. `body` is raw Markdown: bold, line breaks,
and links only. Images are uploaded PNG/JPEG, normalized to JPEG at up to
1280 pixels without cropping, stored in the database and served publicly.
App-update posts return null custom button fields; the app supplies its
localized store label and uses `native_store_urls[platform]`. A general post
without both a button label and link uses **Got it / Okej**.

Selection is newest published (publication time, then ID), unseen, pop-up on.
An app-update post also needs a nonempty threshold for the player's platform
and an installed version strictly below it, or the same version with an
`app_build` below the post's build for that platform. An app that sends no
`app_build` is compared by version only. Selection is independent of the
30-post feed limit and the News unread mark.

`POST /api/v1/news/:id/seen` (authenticated, empty body) acknowledges only this
player's pop-up, across devices; repeats return **204**. Missing, draft, or
non-pop-up posts return **404**. Close/Got it or a successful CTA link open
calls it. **Later** makes no request: suppress locally for the current cold
start, then ask again next cold start. `POST /api/v1/news/seen` still marks
only the feed read, not pop-ups. Do not infer update policy from `data.posts`:
the feed is capped; use the lobby's `native_update_popup` flag.

## Watching tables (PID-389)

`WATCHING_TABLES` in `config/deploy.yml` is off (`"false"`) for the beta: the
lobby's `spectatable` list is empty and Watch answers
`ROOM_NOT_AVAILABLE_FOR_SPECTATORS`. Set it to `"true"` and push; successful main CI
automatically deploys the setting to turn watching back on. Admin Game Settings
shows which it is. The app's CI journeys run with it on.

## Secrets

The deploy job reads these GitHub Actions repository secrets
(Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `SSH_PRIVATE_KEY` | Private half of an SSH deploy key whose public half is in `root@95.217.3.224:~/.ssh/authorized_keys` |
| `SSH_KNOWN_HOSTS` | Output of `ssh-keyscan 95.217.3.224` |
| `KAMAL_REGISTRY_PASSWORD` | From `.kamal/secrets-common` |
| `SECRET_KEY_BASE` | From `.kamal/secrets-common` |
| `POSTGRES_PASSWORD` | From `.kamal/secrets-common` |
| `CLASSIC_API_URL` | From `.kamal/secrets-common` |
| `CLASSIC_CLAIM_SECRET` | From `.kamal/secrets-common` |
| `FB_APP_SECRET` | From `.kamal/secrets-common` |

To add them from a checkout that can deploy:

```bash
ssh-keygen -t ed25519 -N '' -C pidro-backend-deploy -f /tmp/pidro-deploy
ssh-copy-id -i /tmp/pidro-deploy.pub root@95.217.3.224
gh secret set SSH_PRIVATE_KEY < /tmp/pidro-deploy
ssh-keyscan 95.217.3.224 2>/dev/null | gh secret set SSH_KNOWN_HOSTS
gh secret set -f .kamal/secrets-common
rm /tmp/pidro-deploy /tmp/pidro-deploy.pub
```

Until all eight exist, the deploy job skips: it passes with a warning that
names the missing ones, and `main` stays green.

`ANTHROPIC_API_KEY` is optional and not in that check. It turns on
**Translate to Swedish** in `/admin/news` (PID-349); without it a deploy runs
as usual and the button says the key is missing. To turn it on:

```bash
gh secret set ANTHROPIC_API_KEY
```

The next deploy hands it to the app. For `just deploy`, set it in
`.kamal/secrets-common` (empty keeps translation off).

`EXPO_ACCESS_TOKEN` is optional too (PID-392). The server sends pushes through
Expo's push API; when the token is set it goes with each request as a bearer
token. Without it Expo still accepts them as long as the Expo project does not turn on enhanced push
security. To set it, create an access token on expo.dev and:

```bash
gh secret set EXPO_ACCESS_TOKEN
```

The app registers its phone with `POST /api/v1/me/push-tokens` (Expo push
token, platform, install id, app version and `app_build`) and forgets it with
`DELETE /api/v1/me/push-tokens/:token` on sign-out. A token signed in from
another account moves to that account. In `/admin/users/:id` the **Push**
section lists the player's phones and has **Send a test push** (title, body,
optional URL in `data.url`); it shows how many phones got it and the latest
pushes with their receipt, which the server reads every 5 minutes once a push
is 15 minutes old. A phone Expo reports as `DeviceNotRegistered` stops getting
pushes until the app registers it again. iOS tokens work with the store build
that carries `expo-notifications` (PID-390); Android tokens also need Marcel's
Firebase (FCM) setup for that build.

`REVENUECAT_SECRET_KEY` and `REVENUECAT_WEBHOOK_SECRET` are optional too and
not in that check. Together they turn on Premium (PID-125):

| Secret | Value |
| --- | --- |
| `REVENUECAT_SECRET_KEY` | RevenueCat project → API keys → a **secret** (v1) key, `sk_...` |
| `REVENUECAT_WEBHOOK_SECRET` | Any long random string; the same value goes into the RevenueCat webhook's Authorization header |

```bash
gh secret set REVENUECAT_SECRET_KEY
openssl rand -hex 32 | gh secret set REVENUECAT_WEBHOOK_SECRET
```

In the RevenueCat dashboard (Integrations → Webhooks), point the webhook at
`https://app.pidro.online/webhooks/revenuecat` and set its Authorization header
to `Bearer <REVENUECAT_WEBHOOK_SECRET>`.

Until both are set, a deploy runs as usual and Premium is off: `/me` says
`premium: false` for everyone, the webhook and
`POST /api/v1/me/entitlements/refresh` answer 503 (the refresh with
`REVENUECAT_NOT_CONFIGURED`), and the Premium grant on a player's admin page is
disabled with a line saying why. For `just deploy`, set them in
`.kamal/secrets-common`.

The four store credentials are also **optional**, outside the required secret
check. Missing credentials show “App Store Connect not connected” or “Google
Play not connected” without affecting the app or deployment:

| GitHub Actions secret | Value |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_PRIVATE_KEY` | The complete multiline `.p8` PEM for that key |
| `PLAY_SERVICE_ACCOUNT_JSON` | The complete multiline Google service-account JSON with access to `com.oneapps.pidro.beta` |

The current Play credential is the same `eas-submit` account EAS uses.
**Do not press Refresh while an Android build is being submitted.** Google
permits one open edit per user: creating a new read edit invalidates that user's
previous edit, including an unfinished publishing edit. Both Refresh controls
show this warning; Apple reads have no such side effect.

A **dedicated read-only Play service account is preferred**. Swap the same
`PLAY_SERVICE_ACCOUNT_JSON` secret when it is available; no client code changes
are needed. Once it is isolated from publishing and other pollers, the timer
can return by setting `PLAY_AUTO_REFRESH=true` in `config/deploy.yml`'s
`env.clear`. It defaults to **false** (`StoreBuilds.Cache`'s `play_auto_refresh`
config flag). Coordinate polling before scaling to multiple nodes.
See [Google's edit lifecycle](https://developers.google.com/android-publisher/edits).

Name each Play release exactly after its native version (for example `3.2.4`).
The tracks API exposes this editable name, not the binary's `versionName`.
The dashboard only accepts a semantic version as a minimum candidate; other
names show an unknown-version warning. Verify the name matches the binary.

Deploy passes the two IDs unchanged. It base64-encodes the PEM and JSON into
`ASC_PRIVATE_KEY_BASE64` and `PLAY_SERVICE_ACCOUNT_JSON_BASE64`, masks those
values, and passes them through Kamal's secret environment file as single
lines. `runtime.exs` decodes them in memory. Local development may instead use
the original multiline environment variables; tests ignore all four. Never
paste credentials into logs or screenshots. App Store Connect calls are GETs.
Play creates a temporary edit to read tracks, then attempts deletion even if
the read fails, retrying transient DELETE failures twice. It never commits an
edit or publishes a release. Failed cleanup is shown as an error.
Network loss or process termination cannot guarantee server-side deletion.

## Rolling back

```bash
mise exec -- scripts/rollback --dry-run      # list versions, show what would happen
mise exec -- scripts/rollback                # back to the version before the running one
mise exec -- scripts/rollback 1a2b3c4        # back to a given retained version
```

The script lists the retained app containers (`config/deploy.yml` keeps 5),
runs `kamal rollback` (which backs up the database first and smoke-tests
afterwards), then checks that `kamal app version` is the target and that `/up`
answers 200. It runs from a local checkout with `.kamal/secrets-common`, the
same way as `just deploy`.

A rollback does not stop an automatic deploy already queued or in progress.
Push a focused-proven fix or revert to `main`; successful push CI deploys it.

**Roll back** when production is broken for players right now and the release
is the cause: games fail to start or finish, sign-in fails, the app cannot
connect. A rollback takes about a minute; a fix forward takes affected CI plus
deployment.

**Fix forward** instead (push a fix or `git revert` to `main`) when:

- the bad release ran a migration the older code cannot work with. Migrations
  are not reversed, so an old image against the new schema can be worse;
- the release adds a field to a room seat (`Seat`): an older image cannot decode
  the rooms the newer one saved and drops them. PID-399 (`app_build`) is one;
- the release changes the token payload or anything else
  [docs/deployment/kamal_hetzner.md](deployment/kamal_hetzner.md#token-payload-rollback)
  marks as roll-forward only;
- the problem is a limit or another environment value: change
  `config/deploy.yml`, validate the affected behavior and push to auto-deploy it;
- it is cosmetic or affects few players, and a validated release is close.

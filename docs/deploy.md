# Deploying

A green `main` deploys itself. Nobody runs `just deploy` for a normal change.

## How a commit reaches production

1. A push to `main` runs **Backend CI** (`.github/workflows/ci.yml`).
2. When it passes, **Deploy** (`.github/workflows/deploy.yml`) starts for that
   exact commit:
   - **Game journeys** and **Account journeys**: pidro-frontend's reusable
     workflows (`game-e2e.yml`, `account-e2e.yml` at its `main`) boot this
     backend commit and play the app's journeys against it.
   - **Deploy production**, only if both pass: `kamal deploy` from a checkout
     of the commit, the same as `just deploy`. Its hooks back up the database,
     run migrations against the new image, wait for `/up`, and smoke-test
     production (`ops/smoke-production`). Then it checks that
     `kamal app version` is the commit and that `/up` answers 200.
3. If the journeys fail, nothing deploys and the run is red on the journey
   job. If the deploy fails, the run is red on **Deploy production**; Kamal
   leaves the previous container serving when the new one never turns healthy.

Only the newest green commit ships. A newer commit cancels the journeys of an
older one, and replaces an older deploy that is still waiting. A deploy that
is already running is never cancelled.

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

**New app-update post** fills both platforms from their live store builds.
Review both values before publishing: that post owns both minimums, including
empty ones. The News editor warns, without blocking, when a version exceeds
the live build. See the frontend's `docs/store-builds.md` for the release steps.

When a store build is live, publish an **App update** post in `/admin/news`.
Set **Android: show below version** and **iPhone: show below version** to the
live versions (for example `3.2.4`). Leave a platform empty until its build is
live: empty means nobody on that platform. The newest published app-update
post supplies both minimums immediately, even with **Show as pop-up** off.
Drafts do not change the minimums. Unpublishing restores the previous published
update's minimums, or the environment fallback if none remains.

`MINIMUM_NATIVE_*` in `config/deploy.yml` is now **only the fallback when no
published app-update post exists**. Store destinations remain in `env.clear`;
the next automatic deploy applies changes to those URLs:

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
both maps keyed by `android`/`ios`. The app requires both entries for its platform
and opens only the supplied URL. `native_update_popup` is true when the newest
published app-update post has **Show as pop-up** on. New apps then suppress the
minimum-version fallback card: a seen pop-up must not reappear as that fallback.
False (or absent on an older server) preserves the fallback. Old apps ignore
the additive fields and keep their existing store notice.

### News pop-up contract (PID-363)

Authenticated `GET /api/v1/news?locale=sv&platform=android&app_version=3.2.3`
returns `data.posts` (latest 30), `data.unread`, and `data.popup` (always present,
a localized post or `null`). `locale` is `en` or `sv`, `platform` is `android`
or `ios`, and `app_version` is the installed native version. Missing/invalid
platform or version excludes app-update pop-ups, not general News pop-ups.

Posts and pop-ups have `id`, `title`, `body`, `published_at`, `eyebrow`,
`image_url`, `button_label`, `button_url`, `show_as_popup`, `app_update`,
`show_below_android`, and `show_below_ios`. Optional fields are null. Swedish
falls back to English per field. `body` is raw Markdown: bold, line breaks,
and links only. Images are uploaded PNG/JPEG, normalized to JPEG at up to
1280 pixels without cropping, stored in the database and served publicly.
App-update posts return null custom button fields; the app supplies its
localized store label and uses `native_store_urls[platform]`. A general post
without both a button label and link uses **Got it / Okej**.

Selection is newest published (publication time, then ID), unseen, pop-up on.
An app-update post also needs a nonempty threshold for the player's platform
and an installed version strictly below it. Selection is independent of the
30-post feed limit and the News unread mark.

`POST /api/v1/news/:id/seen` (authenticated, empty body) acknowledges only this
player's pop-up, across devices; repeats return **204**. Missing, draft, or
non-pop-up posts return **404**. Close/Got it or a successful CTA link open
calls it. **Later** makes no request: suppress locally for the current cold
start, then ask again next cold start. `POST /api/v1/news/seen` still marks
only the feed read, not pop-ups. Do not infer update policy from `data.posts`:
the feed is capped; use the lobby's `native_update_popup` flag.

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

A rollback does not stop the next green `main` from deploying. Push the fix,
or a revert, right behind it.

**Roll back** when production is broken for players right now and the release
is the cause: games fail to start or finish, sign-in fails, the app cannot
connect. A rollback takes about a minute; a fix forward takes CI plus the
journeys.

**Fix forward** instead (push a fix or `git revert` to `main`) when:

- the bad release ran a migration the older code cannot work with. Migrations
  are not reversed, so an old image against the new schema can be worse;
- the release changes the token payload or anything else
  [docs/deployment/kamal_hetzner.md](deployment/kamal_hetzner.md#token-payload-rollback)
  marks as roll-forward only;
- the problem is a limit or another environment value: change
  `config/deploy.yml` and let `main` deploy it;
- it is cosmetic or affects few players, and a fix is minutes away.

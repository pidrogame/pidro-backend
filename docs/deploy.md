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

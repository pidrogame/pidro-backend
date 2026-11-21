# Switch day (Dec 1)

On switch day the new app goes live under Classic's ids: `com.oneapps.pidro`
on both stores, App Store app `1137091987`. Until then the server sends players
to the beta (`com.oneapps.pidro.beta`, TestFlight `2JR95b65`, App Store Connect
app `6816832730`). Every value below is an environment variable with the beta
value as its default (`config/runtime.exs`), so the switch is one change to
`config/deploy.yml`.

| Variable | Drives | Beta default |
| --- | --- | --- |
| `NATIVE_STORE_URL_IOS`, `NATIVE_STORE_URL_ANDROID` | Store buttons on invite and player pages, email store links, the lobby's update notice | TestFlight link, beta Play listing |
| `NATIVE_ANDROID_PACKAGE` | The app the Android invite/player button opens (`intent://…;package=…`), and the pages' wording: a `.beta` package says "Get Pidro Beta", any other "Get Pidro" | `com.oneapps.pidro.beta` |
| `NATIVE_APP_SCHEME` | The app the iPhone invite/player button opens (`<scheme>://j/<code>`) | `pidro-mobile-beta` |
| `STORE_BUILDS_ASC_APP_ID`, `STORE_BUILDS_PLAY_PACKAGE` | The store records [Store builds](https://app.pidro.online/admin/store-builds) reads and links to | `6816832730`, `com.oneapps.pidro.beta` |
| `STORE_BUILDS_IOS_TRACK` | `testflight` (Friends group) or `app_store` (the App Store version in review or live) | `testflight` |
| `STORE_BUILDS_PLAY_TRACK` | The Play track players install from | `beta` |

## Before the day

- The Play service account (`PLAY_SERVICE_ACCOUNT_JSON`) has read access to
  `com.oneapps.pidro` in Play Console, not only to the beta. The App Store
  Connect key is team-wide. Without access, Store builds shows the error;
  players are not affected.
- `assetlinks.json` serves `com.oneapps.pidro` with the fingerprint in
  `config/config.exs`. It must be the **Play app-signing** certificate of
  Classic's Play app (Play Console → Test and release → App integrity → App
  signing → SHA-256). If it differs, set `ASSETLINKS` in `config/deploy.yml`
  (format in `config/config.exs`) in the same change; otherwise Android opens
  invite links in the browser instead of the app.

## 1. The lines for `config/deploy.yml`

In `env.clear`, replace the two store URLs and add the six lines after them:

```yaml
    NATIVE_STORE_URL_ANDROID: "https://play.google.com/store/apps/details?id=com.oneapps.pidro"
    NATIVE_STORE_URL_IOS: "https://apps.apple.com/app/id1137091987"
    NATIVE_ANDROID_PACKAGE: "com.oneapps.pidro"
    NATIVE_APP_SCHEME: "pidro-mobile"
    STORE_BUILDS_ASC_APP_ID: "1137091987"
    STORE_BUILDS_PLAY_PACKAGE: "com.oneapps.pidro"
    STORE_BUILDS_IOS_TRACK: "app_store"
    STORE_BUILDS_PLAY_TRACK: "production"
```

Leave `MINIMUM_NATIVE_ANDROID` / `MINIMUM_NATIVE_IOS` alone: they only apply
when no app-update post is published, and step 3 sets the minimums.

## 2. The order

1. **Release.** The new app is live for everyone: the App Store version is
   Ready for Distribution and the Play production release is rolled out.
   Check both public listings. Don't flip before this: the server would send
   invitees to Classic, which can't open `/j/` links.
2. **Flip and deploy.** Commit the lines above alone (`PID-…: Switch day`),
   push to `main`; green Backend CI deploys it. Then check:
   - with a fresh invite code from the app,
     `NATIVE_APP_SCHEME=pidro-mobile NATIVE_ANDROID_PACKAGE=com.oneapps.pidro PIDRO_INVITE_CODE=<code> ops/smoke-production`
     passes (unpinned, the smoke accepts beta or production);
   - the invite page on a phone opens the new app and its store button goes to
     the public listing;
   - Store builds shows **App Store** and **Play production**; press Refresh
     for Google Play.
3. **App-update post.** In Store builds, **New app-update post** fills the
   minimums from the live production builds. Review and publish it. Until
   then the previous post's beta minimums still nudge, now to the public
   listings.

## 3. Rolling back

The change is environment only, so revert it rather than the image:
`git revert <switch-day commit>`, push to `main`, and green CI deploys the beta
values again (see "Fix forward" in [../deploy.md](../deploy.md#rolling-back)).
Check with
`NATIVE_APP_SCHEME=pidro-mobile-beta NATIVE_ANDROID_PACKAGE=com.oneapps.pidro.beta PIDRO_INVITE_CODE=<code> ops/smoke-production`.

`scripts/rollback` is faster but restarts the previous container; run the
pinned smoke afterwards to see which values it serves. If an app-update post
for the production builds is already published, unpublish it too: otherwise
it nudges players toward builds the beta links don't offer.

# Ads before solo games (PID-123)

The server decides who watches a short ad before a solo game and when; the app
only follows `/me`. Online tables never have ads.

## Who

Eligible means all three: `ads_enabled` is on, the player is an adult
(`age_band == "18_plus"`), and the player is not premium. Everyone else gets
`eligible: false` and never an ad.

## When

`PidroServer.Ads.Schedule`, a pure function of the admin values, the player's
finished games in this app (`player_profiles.games_played`, bot games included;
the Classic record never counts, so a returning veteran gets the same free games
as anyone) and
`player_profiles.solo_games_started` (counted when a solo room's game starts):

- No ad while finished games < `ads_free_games` (10).
- Then the next solo start, number `solo_games_started + 1`, needs an ad when it
  is a multiple of `ads_early_every_n` (3): the 3rd, 6th, ... 39th.
- Once `solo_games_started >= ads_games_until_steady` (40), a multiple of
  `ads_steady_every_n` (2) instead: the 42nd, 44th, ...

`GET /api/v1/auth/me` carries
`ads: {eligible, next_game_needs_ad, games_until_ad, free_games_left}`. A client
that shows ads reads it as `/auth/me?ads_aware=true`, so its offers are counted
and an old build's are not.

## The flag and the credit

- The app shows the ad, then reports it: `POST /api/v1/me/ads/watched`, or
  `POST /api/v1/me/ads/unavailable` when none could be shown (no fill, an
  error, no SDK). Either gives one credit, valid 10 minutes. Backing out is
  `POST /api/v1/me/ads/dismissed`: counted, no credit.
- It then creates the solo room with `"ads_aware": true`. When the next game
  needs an ad and there is no credit, the answer is `402`
  `{"error": "AD_REQUIRED", "ads": {...}}`. The start of a solo game uses up the
  credit, so a create that fails or a response that never arrives costs no
  second ad.
- Rematches in a solo room are not checked; their start moves the schedule
  and uses up a credit like any solo game.
- A request without `ads_aware` (3.2.4 and older) is never checked.
- The server cannot see the ad. A tampered client can claim a credit without
  watching; that costs one ad and nothing else.

## Counting

`ad_events` keeps `offered` (once per needed game, when an ad-aware `/me` or a
`402` says so), `watched`, `unavailable` and `dismissed`, with the user id and the time and
nothing else. Deleting the account deletes its events.

## Admin

Pidro Ops → Setup → Ads (`/admin/ads`): the five values with Save, stored in
`app_settings` and read on every `/me`, so a change applies on the next app
refresh without a deploy. `ads_enabled` is the kill switch: off, nobody is
eligible and no solo room is held back. Below, the last 14 days of the four
counts and how many free adults are past the free games.

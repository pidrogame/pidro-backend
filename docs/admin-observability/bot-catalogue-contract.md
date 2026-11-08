# Bot catalogue contract

Status: backend review-ready, 2026-10-22; originally published as a draft
integration handoff. Feature branch `admin-ops/bot-catalogue`, not deployed.
GameDetailLive and card_components belong to the separate Watch branch.

## Public HTTP API

`GET /api/v1/bots` is additive and does not require authentication. Response:

```json
{
  "data": [
    {
      "id": "marcel",
      "name": "Marcel",
      "description": "",
      "avatar_url": "https://BACKEND_ORIGIN/images/bots/marcel.svg",
      "strategy": "search",
      "tempo": "quick",
      "home": "anywhere",
      "lines": []
    }
  ]
}
```

Each entry contains **only** `id`, `name`, `description`, `avatar_url`,
`strategy`, `tempo`, `home`, `lines`. All but `lines` are strings; description
can be empty. `strategy` is `rulebook`, `random` or `search` (PID-403: the
character plays the odds); older servers omit it, and a client treats a missing
or unknown value as an honest rulebook game. `tempo` is `quick`, `steady` or
`slow`: how fast the character acts at the table (PID-378); older servers omit
it, so treat a missing value as `steady`. `home` is `anywhere`, `finland` or `louisiana`: where the character
is from (PID-404). `lines` is a list of zero to eight trimmed, nonblank strings
of at most 40 characters: what the character says while thinking, written as
language-neutral table noises, so one list serves every app language. Older
servers omit both; treat a missing `home` as `anywhere` and missing `lines` as
none. IDs are opaque,
immutable strings: legacy IDs remain exactly `marcel`, `antti`, `jocke`; new profiles receive a
server-generated UUID string. Do not enumerate persona IDs in client code.
Catalogue reads include disabled profiles so seated identities still resolve.
There is no public enabled flag, module name, process identifier,
image bytes, admin identity, user account, or rating in a profile.

Use backend-origin absolute `avatar_url` as returned. Do not derive a URL from
an arbitrary ID or fetch a user-provided remote URL. URLs use the endpoint's
configured public origin, as existing user avatars do.

## Optional additions to existing payloads

Existing `bot_persona` remains a string or null. It is a persona ID, **not**
the `bot_ROOM_position` player/seat identifier and not difficulty.

Serialized seats (including game channel room snapshots and room/readiness
HTTP projections) gain optional `bot_profile`:

```json
{
  "occupant_type": "bot",
  "bot_persona": "marcel",
  "bot_profile": {
    "id": "marcel",
    "name": "Marcel",
    "description": "",
    "avatar_url": "https://BACKEND_ORIGIN/images/bots/marcel.svg",
    "tempo": "steady",
    "home": "anywhere",
    "lines": []
  }
}
```

Human/vacant seats and human-replacement substitutes have `bot_profile: null`.
Human replacements retain existing reservation/identity semantics; do not label
them as a catalogue persona merely because control is automated.

Room HTTP seat projections additionally populate existing `username`,
`display_name`, `avatar_url` from the catalogue for persona bots. Lobby seat
`player` summaries carry `bot_persona`, the same optional `bot_profile`, and
existing `username`, `display_name`, `avatar_url` with authoritative profile
values. Existing `player.id` and room `positions` identifiers are unchanged.
A seat's `bot_profile` carries the profile's current `strategy`; no other
strategy field is added to public seats or lobby summaries.

Watch's separate lifecycle path, `RoomManager.get_seat_lifecycle/1` through
`Games.SeatLifecycle.with_names/1`, also supplies `bot_profile` plus authoritative
`username`, `display_name`, and `avatar_url` for `status: :permanent_bot` seats.
It reads the same cached catalogue, with no per-seat database queries. Unknown
personas have null profile/avatar and `Bot` for both names. Human, vacant and
human-reserved substitute lifecycle seats have null `bot_profile`; their existing
account identity, decision and reservation semantics are unchanged.

All additions are optional from a client's perspective: older servers omit
them, older builds ignore them. Existing native builds keep their built-in
legacy drawings. At the frontend source commit below, UUID persona values
pass through the room normalizers/runtime lifecycle validator without being
rejected, but `PlayerAvatar` chooses `BotPersonaFace` for any nonempty persona:
its three-entry face map renders only the SVG background for an unknown ID.
It does not use `avatar_url` for bots. This is source-verified non-crashing
degradation, not a device-tested generic-face fallback.

The following client orb must add the metadata-backed avatar path and widen
its TypeScript-only persona union. After that compatible JS/client release,
future catalogue additions require neither native dependencies nor a native
build. Following clients should prefer `bot_profile`, then an entry in
`GET /api/v1/bots` matching `bot_persona`, then the fallback below. The backend
does not spoof a legacy ID for a new persona to conceal old-client limitations.

## Portrait assets and fallback

Built-in static URLs, on the backend public origin:

- `/images/bots/marcel.svg`
- `/images/bots/antti.svg`
- `/images/bots/jocke.svg`

These are faithful static exports of
`pidrogame/pidro-frontend/packages/mobile/src/components/ui/BotPersonaFace.tsx`
at commit `df95bb8b6845f738cc669d840f17f51b86b4eb08`, not new illustrations.
Provenance/export details are in
`apps/pidro_server/priv/static/images/bots/README.md`. They preserve the source
square viewBox; consumers apply the existing circular avatar crop.

Uploaded portraits are normalized JPEG, served publicly at
`GET /api/v1/bots/:id/avatar/:sha256`, `Content-Type: image/jpeg`, `nosniff`,
immutable one-year caching. Wrong/noncurrent versions return 404. Replacing an
upload changes its hash/URL; re-fetch profile metadata rather than modifying
URLs. Only the current upload is retained. Built-in SVGs are trusted tracked
assets, never user-uploaded SVGs.

**Unknown persona contract:** an absent/unresolvable profile yields
`bot_profile: null`; display name is `Bot` and avatar is null in enriched
projections. Clients must accept any string ID without throwing. If metadata
is absent, preserve the existing artwork/name fallback for the three known
legacy IDs; for any other ID show a neutral bot/avatar placeholder and `Bot`.
An image fetch failure must show that placeholder, not break the seat/table.
Do not invent an SVG path from the unknown ID or show an internal seat ID.

## Allocation and lifetime

- Room crew order remains seeded/shuffled; allocation filters disabled IDs,
  incorporates newly added enabled IDs, and chooses an unused identity first.
- A table seats its own crowd first (PID-404): at room creation the enabled
  profiles whose `home` is the room's rule set (`finland` for Finnish, the
  default; `louisiana` for Louisiana) or `anywhere` are shuffled with the
  room's seed, then the rest, shuffled after them. A room reaches the other
  crowd only when its own is exhausted. With only the three legacy profiles
  (all `anywhere`) the shuffle input, and so every seeded crew, is unchanged.
- With four enabled profiles, four seats have four distinct persona IDs. When
  the enabled pool is exhausted, the first eligible persona can repeat.
- With no enabled profiles, or before the new table is migrated, allocation
  falls back to the original three IDs in deterministic legacy input order
  (the existing room shuffle still applies). Games do not fail for an empty
  catalogue. The public catalogue still resolves those legacy IDs.
- Disabling/renaming a profile does not remove or change a seated persona ID.
  Profile presentation is current catalogue metadata on subsequent snapshots;
  strategy is captured separately when seated and never read from a public
  payload, so after an admin edit a seated character can play the strategy it
  was seated with while its profile already shows the new one. Process reattachment and rematch keep that seat's persona/strategy.
- Catalogue changes notify connected catalogue admin views. They do not emit
  a new game/lobby roster event by themselves; clients can re-fetch catalogue
  metadata, and subsequent normal room snapshots use current profile data.
- No bot persona is inserted into users, ratings, progression or auth tables.

## Admin contract

`/admin/bots` uses existing authenticated admin sessions and password-change
gates, including event-time session revalidation. It also refuses the local
development auth bypass: editing requires a real admin account.

The LiveView supports list/add/edit and disabling (no hard delete). The stable
ID is read-only; form input cannot set it. The editor is keyed by the selected
ID, and the hidden form ID rejects delayed submissions for another selection.
Fields:

- `bot[name]`: required, max 60 characters.
- `bot[description]`: public text, max 500 characters, empty allowed.
- `bot[enabled]`: boolean, controls only new assignments.
- `bot[strategy]`: allowlisted `rulebook` (production default), `random`
  (existing RandomStrategy) or `search` (`Pidro.Bot.Search`, PID-403; the
  seeded Antti, Jocke and Marcel play it), affects newly seated bots and their
  substitutes only. No dynamic atoms
  or module names accepted. Legacy difficulty values still resolve to the
  production rulebook, as before; persona identity is not difficulty.
- `bot[home]`: `anywhere` (default), `finland` or `louisiana`; a check
  constraint holds the same set.
- `bot[lines]`: a textarea, one line per line; each is trimmed and blank ones
  are dropped, then at most eight of at most 40 characters each.
- `bot[portrait]`: `marcel`, `antti`, `jocke`, or `upload` when one exists.
- LiveView upload `avatar`: one PNG/JPEG, at most 5 MiB. Signature-checked;
  maximum 8192px side and 16 megapixels; reused bounded ImageMagick normalizer
  strips metadata, crops to 256×256 JPEG, and caps the output at 64 KiB.
  A successful upload selects `upload`. No executable SVG, arbitrary remote
  URLs, or server-side URL fetching. Invalid replacement leaves saved data
  unchanged.

## Migration and integration

Migration `20261022120000_create_bot_profiles` adds only its own table and
strategy constraint. Seeds use fixed legacy IDs with `ON CONFLICT DO NOTHING`.
No existing user/room/game table is changed; down drops only bot_profiles.
Migrate before serving catalogue administration. Application startup tolerates
an absent catalogue table and serves legacy fallback; after migration restart
the application or open `/admin/bots` to refresh its node-local snapshot.
Admin writes refresh that snapshot in its serialized owner and distribute
PubSub invalidations; other owners read fresh catalogue data, not stale snapshots.
Game action/seat serialization paths do not query the database per seat.

The coordinator should integrate backend assets/context before Watch/client
consumers. Frontend work is separate; this backend branch does not change
React/Expo types or views. Verification and remaining limitations are
recorded in `docs/admin-observability/bot-catalogue.md`.

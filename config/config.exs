# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pidro_server, ecto_repos: [PidroServer.Repo]

config :pidro_server, :game_report_archive_lookup, PidroServer.GameArchive

config :pidro_server, PidroServer.Games.RoomManager, grace_period_ms: 120_000

# Lifecycle timeouts for the disconnect cascade and room lifecycle.
# All values are in milliseconds. Override per-environment or via env vars in runtime.exs.
config :pidro_server, PidroServer.Games.Lifecycle,
  hiccup_timeout_ms: 20_000,
  grace_timeout_ms: 120_000,
  empty_room_ttl_ms: 30_000,
  finished_room_ttl_ms: 300_000,
  idle_waiting_ttl_ms: 600_000,
  invited_waiting_ttl_ms: 7_200_000,
  reconnect_turn_extension_ms: 10_000,
  health_check_interval_ms: 60_000,
  presence_debounce_ms: 3_000,
  turn_timer_bid_ms: 45_000,
  turn_timer_play_ms: 30_000,
  consecutive_timeout_threshold: 3,
  bot_delay_ms: 1_500,
  bot_delay_variance_ms: 800,
  bot_min_delay_ms: 300,
  trick_transition_delay_ms: 1_500,
  sweep_trick_delay_ms: 500,
  hand_transition_delay_ms: 6_000,
  second_deal_transition_delay_ms: 11_500,
  deal_transition_delay_ms: 5_000

# Rate-limit policies for PidroServerWeb.Plugs.RateLimit: `limit` requests per
# `scale_ms` window, keyed by the client address (:ip), the authenticated user
# (:user), the hashed identifier/email param (:identifier) or the hashed
# install_id param (:install_id), or a hashed named param ({:param, name}).
# Numeric only, no boolean off switch.
# config/dev.exs restates every policy at 10x for the frontend end-to-end
# harness, config/test.exs sets 1_000_000, and config/runtime.exs merges
# RATE_LIMIT_<POLICY>_LIMIT / _SCALE_MS overrides.
config :pidro_server, PidroServerWeb.Plugs.RateLimit,
  user_search: %{limit: 30, scale_ms: 60_000, key: :user},
  friend_add: %{limit: 30, scale_ms: 3_600_000, key: :user},
  login: %{limit: 10, scale_ms: 60_000, key: :ip},
  register: %{limit: 10, scale_ms: 600_000, key: :ip},
  password_reset: %{limit: 3, scale_ms: 900_000, key: :ip},
  password_reset_identifier: %{limit: 3, scale_ms: 3_600_000, key: :identifier},
  password_reset_confirm: %{limit: 5, scale_ms: 900_000, key: :ip},
  classic_sign_in_code: %{limit: 10, scale_ms: 900_000, key: :ip},
  classic_sign_in_code_identifier: %{limit: 3, scale_ms: 3_600_000, key: {:param, "login"}},
  room_create: %{limit: 10, scale_ms: 60_000, key: :user},
  room_lookup: %{limit: 120, scale_ms: 60_000, key: :ip},
  invite_mint: %{limit: 10, scale_ms: 60_000, key: :user},
  invite_preview: %{limit: 60, scale_ms: 60_000, key: :ip},
  # `/j/:code` arrives through Vercel, so the origin cannot safely treat its
  # edge address as one visitor. Bound work per invite and keep API previews in
  # their independent per-client bucket.
  invite_page: %{limit: 300, scale_ms: 60_000, key: {:param, "code"}},
  invite_capture: %{limit: 20, scale_ms: 1_800_000, key: :ip},
  invite_capture_code: %{limit: 200, scale_ms: 1_800_000, key: {:param, "code"}},
  friend_capture_slug: %{limit: 200, scale_ms: 1_800_000, key: {:param, "slug"}},
  invite_deferred: %{limit: 5, scale_ms: 1_800_000, key: :ip},
  invite_deferred_install: %{limit: 2, scale_ms: 1_800_000, key: :install_id},
  invite_redeem: %{limit: 10, scale_ms: 60_000, key: :user},
  guest_create: %{limit: 10, scale_ms: 3_600_000, key: :ip},
  guest_create_daily: %{limit: 40, scale_ms: 86_400_000, key: :ip},
  guest_create_install: %{limit: 3, scale_ms: 3_600_000, key: :install_id},
  room_join: %{limit: 30, scale_ms: 60_000, key: :user},
  # Joins that send a seat password, per player, and wrong ones per table, so
  # the 10_000 four-digit passwords cannot be walked.
  seat_password: %{limit: 10, scale_ms: 600_000, key: :user},
  seat_password_room: %{limit: 30, scale_ms: 600_000, key: {:param, "code"}},
  auth_upgrade: %{limit: 10, scale_ms: 600_000, key: :ip},
  auth_age: %{limit: 10, scale_ms: 600_000, key: :user},
  provider_auth: %{limit: 10, scale_ms: 60_000, key: :ip},
  classic_claim: %{limit: 10, scale_ms: 600_000, key: :ip},
  classic_help: %{limit: 5, scale_ms: 3_600_000, key: :ip},
  avatar_upload: %{limit: 10, scale_ms: 600_000, key: :user},
  avatar_read: %{limit: 300, scale_ms: 60_000, key: :ip}

# PidroServerWeb.Plugs.TrustedProxy honours X-Forwarded-For / X-Forwarded-Proto
# only when this is true and the TCP peer is proxy-side. config/runtime.exs sets
# it from TRUST_PROXY_HEADERS (default true in prod, false everywhere else).
config :pidro_server, trust_proxy_headers: false

config :pidro_server, PidroServer.Accounts.ClassicClient,
  base_url: "http://localhost:4001",
  secret: ""

config :pidro_server, PidroServer.Accounts.ClassicNameReservations, cutoff_date: ~D[2026-09-27]

config :pidro_server, PidroServer.Accounts.ProviderIdentity,
  apple_jwks_url: "https://appleid.apple.com/auth/keys",
  apple_audience: ["com.oneapps.pidro", "com.oneapps.pidro.beta"],
  facebook_jwks_url: "https://limited.facebook.com/.well-known/oauth/openid/jwks/",
  facebook_graph_url: "https://graph.facebook.com/v24.0",
  facebook_app_id: "345200965110578",
  facebook_app_secret: "",
  jwks_cache_ttl_ms: 300_000

# Lifetimes in seconds, read when used. config/runtime.exs can shorten them
# outside production (CLASSIC_CLAIM_TICKET_TTL_SECONDS, PASSWORD_RESET_TTL_SECONDS).
config :pidro_server, PidroServer.Accounts.ClassicClaims, ticket_ttl_seconds: 10 * 60
config :pidro_server, :password_reset_ttl_seconds, 60 * 60

# Skill-tier thresholds (PID-48). Bands are read off Rating.ordinal/1 (mu - 3*sigma).
# Launch defaults, tunable — NOT finely calibrated; recalibrate against the real
# ordinal distribution.
#
# Provisional clears once EITHER gate opens: games_count >= provisional_min_games
# OR sigma < provisional_max_sigma. Games-count is the reliable driver — OpenSkill
# sigma floors ~6.06 with the default model, so a sub-6.06 sigma gate would never
# clear; provisional_max_sigma sits just above the floor as a fast-converger early
# out, while min_games guarantees everyone reaches a real band after 10 rated games.
# provisional_max_sigma stays below the 8.333 schema default so never-rated users
# remain provisional.
config :pidro_server, PidroServer.Rating.Tier,
  provisional_min_games: 10,
  provisional_max_sigma: 6.5,
  bronze_min: 0.0,
  silver_min: 10.0,
  gold_min: 18.0,
  platinum_min: 26.0,
  master_min: 34.0

# Veteran progression (PID-49). XP curve + bonuses + milestone titles. win_bonus
# 50 is the proven legacy Pidro 1 value (so PID-53 imports earn the same totals);
# extra_bonus is the events lever (flat, no streaks yet). titles are launch
# PLACEHOLDERS, not final copy — tunable. The curve is a re-paced power law
# (threshold(level) = round(curve_coefficient * level ** curve_exponent)),
# data-calibrated against Pidro 1: L100 caps at 800k XP, then Prestige adds one
# star per prestige_step (500k) XP past the cap (top player 5.0M → ★8). Set
# `thresholds:` to override the level boundaries verbatim.
config :pidro_server, PidroServer.Progression,
  win_bonus: 50,
  extra_bonus: 0,
  max_level: 100,
  curve_coefficient: 80,
  curve_exponent: 2.0,
  prestige_step: 500_000,
  # thresholds: nil,  # optional explicit ascending list; nil = generate from params
  titles: %{
    1 => "Rookie",
    5 => "Apprentice",
    10 => "Journeyman",
    20 => "Veteran",
    35 => "Expert",
    50 => "Master",
    75 => "Grandmaster",
    100 => "Legend"
  }

# Configures the endpoint
config :pidro_server, PidroServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PidroServerWeb.ErrorHTML, json: PidroServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PidroServer.PubSub,
  live_view: [signing_salt: "9OPTkHQU"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :pidro_server, PidroServer.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.1",
  pidro_server: [
    args:
      ~w(js/app.js js/invite.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/pidro_server/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.2",
  pidro_server: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/pidro_server", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :outcome, :diagnostic]

# Drop under overload rather than synchronously blocking game callers. The
# collector runs outside the VM; no provider requests happen in game processes.
config :logger, :default_handler,
  formatter: {PidroServer.DiagnosticsFormatter, %{}},
  config: [sync_mode_qlen: 200, drop_mode_qlen: 200, flush_qlen: 1000]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Credentials, deferred matching inputs and the per-install fairness id must
# never appear in application logs.
config :phoenix,
       :filter_parameters,
       ~w(password ticket identity_token access_token install_id referrer platform os_major screen_class locale timezone)

# ---------------------------------------------------------------------------
# Well-known association files (AASA / assetlinks.json), served by
# PidroServerWeb.WellKnownController. Production-correct defaults for every
# environment; config/runtime.exs overrides each list from AASA_APP_IDS,
# AASA_PATHS and ASSETLINKS only when that variable is set. `/j/*` carries
# invite links and `/play/*` player share links; `/app/*` stays listed so the
# live Unity app's links survive the phase-2 proxy cutover. Android App Links
# take their paths from the app manifest, so assetlinks.json has none.
# The Beta (com.oneapps.pidro.beta) and dev Android packages get an entry once
# their signing fingerprints are known; the list accepts more.
# ---------------------------------------------------------------------------
config :pidro_server, PidroServerWeb.WellKnownController,
  ios_app_ids: [
    "LSFK7YF82G.com.oneapps.pidro",
    "LSFK7YF82G.com.marcelfahle.pidro3.dev",
    "LSFK7YF82G.com.oneapps.pidro.beta"
  ],
  ios_paths: ["/j/*", "/play/*", "/app/*"],
  android_packages: [
    %{
      package: "com.oneapps.pidro",
      fingerprints: [
        "11:24:29:B7:D0:61:FA:FF:89:D2:F0:04:92:12:FF:18:24:90:C1:EF:CF:71:00:5D:51:6A:D6:92:66:88:1A:31"
      ]
    },
    # Pidro Beta on Google Play; this is Play's app-signing certificate, not
    # the EAS upload key (Play re-signs what testers install).
    %{
      package: "com.oneapps.pidro.beta",
      fingerprints: [
        "60:DF:21:12:ED:8E:5E:4E:E7:F0:AA:AC:3D:C7:FB:B5:21:C0:7A:9B:02:D3:10:67:62:F2:8E:BA:F1:07:9F:03"
      ]
    }
  ]

# Invite links (PidroServer.Invites.url/1) are `<link_base_url>/<code>`, the
# landing page proxied on pidro.online. config/dev.exs and config/test.exs point
# at the local endpoint; config/runtime.exs replaces the value from
# INVITE_LINK_BASE_URL when that variable is set.
config :pidro_server, PidroServer.Invites, link_base_url: "https://www.pidro.online/j"

# Deferred invite hints are node-local and disabled until the matching privacy
# disclosure is live. Runtime configuration may enable the 30-minute store.
config :pidro_server, PidroServer.Invites.DeferredMatcher,
  enabled: false,
  retention_ms: 1_800_000,
  max_candidates: 10_000

config :pidro_server, PidroServerWeb.DeferredInviteCaptureController,
  endpoint_origin: "https://app.pidro.online",
  allowed_origins: ["https://www.pidro.online", "https://app.pidro.online"]

# Idle-guest reaper (PidroServer.Accounts.GuestReaper): every interval_ms it
# deletes guest accounts idle for more than max_idle_days with the account
# deletion recipe. config/test.exs disables it (the SQL sandbox has no owner
# for a timer-driven sweep); config/runtime.exs merges GUEST_REAPER_ENABLED,
# GUEST_REAPER_INTERVAL_MS and GUEST_REAPER_MAX_IDLE_DAYS when set.
config :pidro_server, PidroServer.Accounts.GuestReaper,
  enabled: true,
  interval_ms: 3_600_000,
  max_idle_days: 30

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

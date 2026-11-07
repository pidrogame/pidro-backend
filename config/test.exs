import Config

config :pidro_server, :leagues_start_at, ~U[2026-01-04 19:00:00Z]
config :pidro_server, :league_timer, false

# Exercise real hash/verify behavior without spending production-strength CPU
# on every fixture account.
config :bcrypt_elixir, log_rounds: 4

config :pidro_server, PidroServer.Invites.DeferredMatcher, enabled: true

# Tests cover watching as it works when switched on; the tests of the switch turn it off.
config :pidro_server, :watching_tables, true

config :pidro_server, PidroServer.Accounts.ClassicClient,
  base_url: "https://classic.test",
  secret: "classic-test-secret",
  req_options: [plug: {Req.Test, PidroServer.Accounts.ClassicClient}]

config :pidro_server, PidroServer.Translate,
  api_key: "anthropic-test-key",
  req_options: [plug: {Req.Test, PidroServer.Translate}]

config :pidro_server, PidroServer.Accounts.ProviderIdentity,
  apple_jwks_url: "https://apple.test/auth/keys",
  apple_audience: ["com.oneapps.pidro", "com.oneapps.pidro.beta"],
  facebook_jwks_url: "https://limited.facebook.test/.well-known/oauth/openid/jwks/",
  facebook_graph_url: "https://facebook.test/v24.0",
  facebook_app_id: "345200965110578",
  facebook_app_secret: "facebook-test-secret",
  jwks_cache_ttl_ms: 0,
  req_options: [plug: {Req.Test, PidroServer.Accounts.ProviderIdentity}]

config :pidro_server, PidroServerWeb.DeferredInviteCaptureController,
  endpoint_origin: "http://localhost:4002",
  allowed_origins: ["http://localhost:4002"]

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :pidro_server, PidroServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pidro_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pidro_server, PidroServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "UBA5CSxpt0JC931WeLp1CYEn/RUuDODXDj7CI3bEzJrWFp5/IDWVttDAy99R9Jxd",
  server: false

# In test we don't send emails
config :pidro_server, PidroServer.Mailer, adapter: Swoosh.Adapters.Test

config :pidro_server, :password_reset,
  debug_tokens: true,
  reset_url_base: "http://localhost:5173"

config :pidro_server, PidroServer.Invites, link_base_url: "http://localhost:4002/j"

# The reaper never schedules under the SQL sandbox; tests call
# PidroServer.Accounts.GuestReaper.run_once/0 from their own process.
config :pidro_server, PidroServer.Accounts.GuestReaper, enabled: false

# Archive maintenance is driven explicitly by database integration tests.
config :pidro_server, PidroServer.GameArchive.Maintenance, enabled: false

# Scheduled report retention must not query outside a test's SQL sandbox.
config :pidro_server, PidroServer.GameReports.Cleanup, enabled: false

# Ordinary transactional tests share one sandbox connection: cancelling a writer
# would roll back that unrelated test's transaction. ArchiveCase opts in using
# independent connections, including for real SQL cancellation/outage coverage.
config :pidro_server, :game_archive_enabled, false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :pidro_server, PidroServer.Games.RoomManager, grace_period_ms: 200

# Use short lifecycle timeouts in tests to avoid slow test runs
config :pidro_server, PidroServer.Games.Lifecycle,
  hiccup_timeout_ms: 100,
  grace_timeout_ms: 200,
  empty_room_ttl_ms: 100,
  finished_room_ttl_ms: 500,
  idle_waiting_ttl_ms: 500,
  invited_waiting_ttl_ms: 500,
  reconnect_turn_extension_ms: 50,
  health_check_interval_ms: 500,
  presence_debounce_ms: 50,
  turn_timer_bid_ms: 120,
  turn_timer_play_ms: 90,
  consecutive_timeout_threshold: 3,
  bot_delay_ms: 20,
  bot_delay_variance_ms: 10,
  bot_min_delay_ms: 5,
  dealer_selection_delay_ms: 0,
  trick_transition_delay_ms: 30,
  hand_transition_delay_ms: 40,
  settle_presentation_ms: 40,
  second_deal_transition_delay_ms: 40,
  deal_transition_delay_ms: 40

# Rate limits are effectively unlimited in test. Rate-limit tests lower one
# policy at a time with PidroServerWeb.RateLimitCase.with_limit/3.
config :pidro_server, PidroServerWeb.Plugs.RateLimit,
  user_search: %{limit: 1_000_000, scale_ms: 60_000, key: :user},
  friend_add: %{limit: 1_000_000, scale_ms: 3_600_000, key: :user},
  login: %{limit: 1_000_000, scale_ms: 60_000, key: :ip},
  register: %{limit: 1_000_000, scale_ms: 600_000, key: :ip},
  password_reset: %{limit: 1_000_000, scale_ms: 900_000, key: :ip},
  password_reset_identifier: %{limit: 1_000_000, scale_ms: 3_600_000, key: :identifier},
  password_reset_confirm: %{limit: 1_000_000, scale_ms: 900_000, key: :ip},
  classic_sign_in_code: %{limit: 1_000_000, scale_ms: 900_000, key: :ip},
  classic_sign_in_code_identifier: %{
    limit: 1_000_000,
    scale_ms: 3_600_000,
    key: {:param, "login"}
  },
  room_create: %{limit: 1_000_000, scale_ms: 60_000, key: :user},
  room_lookup: %{limit: 1_000_000, scale_ms: 60_000, key: :ip},
  invite_mint: %{limit: 1_000_000, scale_ms: 60_000, key: :user},
  invite_preview: %{limit: 1_000_000, scale_ms: 60_000, key: :ip},
  invite_page: %{limit: 1_000_000, scale_ms: 60_000, key: {:param, "code"}},
  invite_capture: %{limit: 1_000_000, scale_ms: 1_800_000, key: :ip},
  invite_capture_code: %{
    limit: 1_000_000,
    scale_ms: 1_800_000,
    key: {:param, "code"}
  },
  friend_capture_slug: %{limit: 1_000_000, scale_ms: 1_800_000, key: {:param, "slug"}},
  invite_deferred: %{limit: 1_000_000, scale_ms: 1_800_000, key: :ip},
  invite_deferred_install: %{
    limit: 1_000_000,
    scale_ms: 1_800_000,
    key: :install_id
  },
  invite_redeem: %{limit: 1_000_000, scale_ms: 60_000, key: :user},
  guest_create: %{limit: 1_000_000, scale_ms: 3_600_000, key: :ip},
  guest_create_daily: %{limit: 1_000_000, scale_ms: 86_400_000, key: :ip},
  guest_create_install: %{limit: 1_000_000, scale_ms: 3_600_000, key: :install_id},
  room_join: %{limit: 1_000_000, scale_ms: 60_000, key: :user},
  seat_password: %{limit: 1_000_000, scale_ms: 600_000, key: :user},
  seat_password_room: %{limit: 1_000_000, scale_ms: 600_000, key: {:param, "code"}},
  auth_upgrade: %{limit: 1_000_000, scale_ms: 600_000, key: :ip},
  auth_age: %{limit: 1_000_000, scale_ms: 600_000, key: :user},
  provider_auth: %{limit: 1_000_000, scale_ms: 60_000, key: :ip},
  classic_claim: %{limit: 1_000_000, scale_ms: 600_000, key: :ip},
  classic_help: %{limit: 1_000_000, scale_ms: 3_600_000, key: :ip},
  feedback_note: %{limit: 1_000_000, scale_ms: 3_600_000, key: :ip},
  feedback_note_user: %{limit: 1_000_000, scale_ms: 86_400_000, key: :user},
  feedback_answer: %{limit: 1_000_000, scale_ms: 3_600_000, key: :ip},
  avatar_upload: %{limit: 1_000_000, scale_ms: 600_000, key: :user},
  avatar_read: %{limit: 1_000_000, scale_ms: 60_000, key: :ip}

# Ops routes require a real admin session in tests. Only local development bypasses auth.
config :pidro_server, dev_routes: false

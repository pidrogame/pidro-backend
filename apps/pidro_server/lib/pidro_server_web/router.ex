defmodule PidroServerWeb.Router do
  use PidroServerWeb, :router

  import PidroServerWeb.AdminAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PidroServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :invite_page do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {PidroServerWeb.Layouts, :invite}
    plug :put_secure_browser_headers
    plug PidroServerWeb.Plugs.RateLimit
  end

  # Credential-free URL-encoded beacon sent directly to Phoenix immediately
  # before a matching mobile store navigation. Deliberately has no session or
  # CSRF state; the controller applies exact browser-origin validation.
  pipeline :deferred_capture do
    plug :put_secure_browser_headers
    plug PidroServerWeb.Plugs.RateLimit
  end

  pipeline :dev_layout do
    plug :put_root_layout, html: {PidroServerWeb.Layouts, :dev_root}
  end

  pipeline :fetch_admin do
    plug :fetch_current_admin
  end

  pipeline :require_admin do
    plug :require_authenticated_admin
  end

  pipeline :require_changed_admin_password do
    plug :require_changed_password
  end

  pipeline :redirect_authenticated_admin do
    plug :redirect_if_admin_is_authenticated
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PidroServerWeb.ApiSpec
    plug PidroServerWeb.Plugs.RateLimit
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug PidroServerWeb.Plugs.Authenticate
    # After Authenticate so :user policies see conn.assigns.current_user
    plug PidroServerWeb.Plugs.RateLimit
  end

  pipeline :api_optional_authenticated do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PidroServerWeb.ApiSpec
    plug PidroServerWeb.Plugs.Authenticate, optional: true
    plug PidroServerWeb.Plugs.RateLimit
  end

  pipeline :game_reports do
    plug :accepts, ["json"]
    plug PidroServerWeb.Plugs.Authenticate
  end

  pipeline :public_asset do
    plug PidroServerWeb.Plugs.RateLimit
  end

  scope "/", PidroServerWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/up", HealthController, :up
  end

  scope "/", PidroServerWeb do
    pipe_through :invite_page

    get "/j/:code", InvitePageController, :show, private: %{rate_limit: [:invite_page]}
    get "/play/:slug", PlayPageController, :show
  end

  scope "/", PidroServerWeb do
    pipe_through :deferred_capture

    post "/j/:code/deferred", DeferredInviteCaptureController, :create,
      private: %{rate_limit: [:invite_capture, :invite_capture_code]}

    post "/play/:slug/deferred", DeferredInviteCaptureController, :create,
      private: %{rate_limit: [:invite_capture, :friend_capture_slug]}
  end

  # OpenAPI documentation routes
  scope "/api" do
    pipe_through :api

    get "/openapi", OpenApiSpex.Plug.RenderSpec, spec: PidroServerWeb.ApiSpec
    get "/swagger", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  # API v1 routes
  scope "/api/v1", PidroServerWeb.API do
    pipe_through :api

    get "/bots", BotCatalogueController, :index

    get "/bots/:id/avatar/:version", BotCatalogueController, :avatar,
      private: %{rate_limit: [:avatar_read]}

    # Auth routes without authentication. `private: %{rate_limit: [...]}` names
    # the PidroServerWeb.Plugs.RateLimit policies applied to the route.
    post "/auth/register", AuthController, :register, private: %{rate_limit: [:register]}
    post "/auth/login", AuthController, :login, private: %{rate_limit: [:login]}
    post "/auth/apple", AuthController, :apple, private: %{rate_limit: [:provider_auth]}
    post "/auth/facebook", AuthController, :facebook, private: %{rate_limit: [:provider_auth]}

    post "/auth/password-reset", AuthController, :request_password_reset,
      private: %{rate_limit: [:password_reset, :password_reset_identifier]}

    post "/auth/password-reset/confirm", AuthController, :reset_password,
      private: %{rate_limit: [:password_reset_confirm]}

    # Direct and invited guest creation share the address, daily and install
    # abuse limits.
    post "/auth/guest", AuthController, :guest,
      private: %{rate_limit: [:guest_create, :guest_create_daily, :guest_create_install]}

    # Room routes without authentication
    get "/rooms", RoomController, :index
    get "/rooms/:code", RoomController, :show, private: %{rate_limit: [:room_lookup]}
    # Invite preview for landing pages; never exposes the room code (KD2)
    post "/invites/deferred", DeferredInviteController, :create,
      private: %{rate_limit: [:invite_deferred, :invite_deferred_install]}

    get "/invites/:code", InviteController, :show, private: %{rate_limit: [:invite_preview]}
  end

  scope "/api/v1", PidroServerWeb.API do
    pipe_through :api_optional_authenticated

    post "/classic/verify", ClassicClaimController, :verify,
      private: %{rate_limit: [:classic_claim]}

    post "/classic/sign-in-code", ClassicSignInCodeController, :create,
      log: false,
      private: %{rate_limit: [:classic_sign_in_code, :classic_sign_in_code_identifier]}

    post "/classic/sign-in-code/verify", ClassicSignInCodeController, :verify,
      log: false,
      private: %{rate_limit: [:classic_sign_in_code]}

    post "/classic/claim", ClassicClaimController, :create,
      private: %{rate_limit: [:classic_claim]}

    # `log: false` keeps the message out of Phoenix's parameter logging.
    post "/classic/help", ClassicHelpController, :create,
      log: false,
      private: %{rate_limit: [:classic_help]}
  end

  scope "/api/v1", PidroServerWeb.API do
    pipe_through :public_asset

    get "/users/:user_id/avatar/:version", AvatarController, :show,
      private: %{rate_limit: [:avatar_read]}
  end

  # API v1 authenticated routes
  scope "/api/v1", PidroServerWeb.API do
    pipe_through :game_reports
    post "/game-reports", GameReportController, :create, log: false
  end

  scope "/api/v1", PidroServerWeb.API do
    pipe_through :api_authenticated

    get "/auth/me", AuthController, :me
    delete "/auth/me", AuthController, :delete_me
    post "/auth/upgrade", AuthController, :upgrade, private: %{rate_limit: [:auth_upgrade]}
    post "/auth/age", AuthController, :age, private: %{rate_limit: [:auth_age]}

    # Game state route (authenticated to prevent hand exposure)
    get "/rooms/:code/state", RoomController, :state

    # User routes with authentication
    get "/users/me/stats", UserController, :stats
    get "/users/search", FriendController, :search, private: %{rate_limit: [:user_search]}

    get "/friends", FriendController, :index
    get "/friends/recent", FriendController, :recent
    put "/friends/:user_id", FriendController, :add, private: %{rate_limit: [:friend_add]}
    delete "/friends/:user_id", FriendController, :remove
    post "/friends/:user_id/ignore", FriendController, :ignore
    delete "/friends/:user_id/ignore", FriendController, :unignore
    post "/friends/:user_id/join", FriendController, :join, private: %{rate_limit: [:room_join]}

    get "/blocks", BlockController, :index
    put "/blocks/:user_id", BlockController, :block
    delete "/blocks/:user_id", BlockController, :unblock

    # Player profile route with authentication (own profile)
    get "/profile", ProfileController, :show
    patch "/profile", ProfileController, :update
    get "/profiles/:id", ProfileController, :public
    get "/players/by-slug/:slug", ProfileController, :by_slug
    post "/profile/avatar", AvatarController, :create, private: %{rate_limit: [:avatar_upload]}
    delete "/profile/avatar", AvatarController, :delete

    # Lobby route with authentication (needs user_id for rejoinable rooms)
    get "/lobby", RoomController, :lobby

    # Room routes with authentication
    post "/rooms", RoomController, :create, private: %{rate_limit: [:room_create]}
    post "/rooms/:code/join", RoomController, :join, private: %{rate_limit: [:room_join]}
    delete "/rooms/:code/leave", RoomController, :leave
    post "/rooms/:code/open-seat", RoomController, :open_seat
    post "/rooms/:code/close-seat", RoomController, :close_seat

    # Host controls for waiting rooms (R23)
    post "/rooms/:code/seat", RoomController, :seat
    post "/rooms/:code/lock", RoomController, :lock
    post "/rooms/:code/kick", RoomController, :kick
    post "/rooms/:code/bot", RoomController, :seat_bot
    put "/rooms/:code/seats/:position/hold", RoomController, :hold
    delete "/rooms/:code/seats/:position/hold", RoomController, :release_hold
    post "/rooms/:code/seats/:position/decline", RoomController, :decline_hold
    put "/rooms/:code/seats/:position", RoomController, :set_seat

    # Invite routes (R1, R5, R6, R7); the mint bucket also covers regenerate
    post "/rooms/:code/invites", RoomController, :create_invite,
      private: %{rate_limit: [:invite_mint]}

    post "/invites/:code/redeem", InviteController, :redeem,
      private: %{rate_limit: [:invite_redeem]}

    delete "/invites/:code", InviteController, :delete

    post "/invites/:code/regenerate", InviteController, :regenerate,
      private: %{rate_limit: [:invite_mint]}

    # Spectator routes with authentication
    post "/rooms/:code/watch", RoomController, :watch
    delete "/rooms/:code/unwatch", RoomController, :unwatch
  end

  scope "/admin", PidroServerWeb do
    pipe_through [:browser, :dev_layout, :fetch_admin, :redirect_authenticated_admin]

    get "/", AdminSessionController, :new
    get "/login", AdminSessionController, :new
    post "/login", AdminSessionController, :create
  end

  scope "/admin", PidroServerWeb do
    pipe_through [:browser, :dev_layout, :fetch_admin, :require_admin]

    delete "/logout", AdminSessionController, :delete

    live_session :admin_settings,
      root_layout: {PidroServerWeb.Layouts, :dev_root},
      on_mount: [{PidroServerWeb.AdminAuth, :ensure_authenticated}] do
      live "/admins", Dev.AdminSettingsLive
    end
  end

  scope "/admin", PidroServerWeb.Dev do
    pipe_through [
      :browser,
      :dev_layout,
      :fetch_admin,
      :require_admin,
      :require_changed_admin_password
    ]

    get "/emails/export.csv", EmailExportController, :index
    get "/beta/classic.csv", BetaExportController, :index

    live_session :ops,
      root_layout: {PidroServerWeb.Layouts, :dev_root},
      on_mount: [{PidroServerWeb.AdminAuth, :ensure_authenticated_and_password_changed}] do
      live "/games", GameListLive
      live "/games/:code", GameDetailLive
      live "/game-settings", GameSettingsLive
      live "/history", HistoryLive, :archives
      live "/history/summaries", HistoryLive, :summaries
      live "/history/summaries/:id", HistoryLive, :summary
      live "/history/:id", HistoryLive, :archive
      live "/reports", HistoryLive, :reports
      live "/reports/:id", HistoryLive, :report
      live "/users", UserListLive
      live "/users/:id", UserDetailLive
      live "/emails", EmailMigrationLive
      live "/analytics", AnalyticsLive
      live "/beta", BetaLive
      live "/bots", BotCatalogueLive
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pidro_server, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PidroServerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Domain-association files for iOS universal links and Android app links.
  # No `accepts` plug on purpose: Apple's CDN and Google's verifier must get JSON
  # for any Accept header, and the controller sets the content type itself.
  pipeline :well_known do
  end

  scope "/", PidroServerWeb do
    pipe_through :well_known

    get "/.well-known/apple-app-site-association",
        WellKnownController,
        :apple_app_site_association

    get "/.well-known/assetlinks.json", WellKnownController, :assetlinks

    # Legacy root path Apple still probes before the well-known one.
    get "/apple-app-site-association", WellKnownController, :apple_app_site_association
  end
end

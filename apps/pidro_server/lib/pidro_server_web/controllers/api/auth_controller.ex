defmodule PidroServerWeb.API.AuthController do
  @moduledoc """
  API controller for user authentication operations.

  This controller handles user registration, login, and current user retrieval.
  All endpoints return JSON responses with user data and authentication tokens
  where applicable. Errors are delegated to the FallbackController for
  centralized error handling.

  ## Authentication

  Protected endpoints (like `me/1`) require a valid Bearer token in the
  Authorization header. Tokens are validated via the Authenticate plug.

  ## OpenAPI Documentation

  This controller includes OpenAPI 3.0 specifications for all endpoints:
  - POST /api/v1/auth/register - Register a new user account
  - POST /api/v1/auth/login - Authenticate (username or email) and receive a token
  - POST /api/v1/auth/guest - Create a direct or invited guest account
  - POST /api/v1/auth/upgrade - Upgrade the calling guest in place (R13)
  - GET /api/v1/auth/me - Retrieve current authenticated user
  - DELETE /api/v1/auth/me - Delete the calling account (R15)

  All endpoints are tagged with "Authentication" in the OpenAPI specification.

  Every token mint (register, login, guest, upgrade, password reset) also
  touches `last_seen_at` through `Auth.touch_last_seen/1` (R16).
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger

  alias PidroServer.Accounts.{AgeTerms, Auth, FacebookCredential, ProviderAuth, Token, User}
  alias PidroServer.Emails
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Invites
  alias PidroServer.Invites.{Invite, Redemption}
  alias PidroServer.Mailer
  alias PidroServerWeb.API.{InviteController, UserJSON}
  alias PidroServerWeb.Schemas.{ClassicClaimSchemas, ErrorSchemas, UserSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Authentication"])

  @platforms Redemption.platforms()

  operation(:register,
    summary: "Register a new user",
    description: """
    Creates a new user account with username, email, and password.
    Returns the created user data along with a JWT authentication token.

    The token should be included in subsequent requests in the Authorization header
    as a Bearer token: `Authorization: Bearer <token>`

    ## Validation Rules
    - Username must be at least 3 characters and unique
    - Email must be valid format and unique
    - Password must be at least 8 characters
    """,
    request_body: {"User registration data", "application/json", UserSchemas.RegisterRequest},
    responses: [
      created:
        {"User created successfully", "application/json", UserSchemas.UserWithTokenResponse},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      unprocessable_entity:
        {"Validation errors", "application/json", ErrorSchemas.validation_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Register a new user.

  Registers a new user with the provided parameters. On successful registration,
  generates an authentication token and returns the user data along with the token.

  Returns HTTP 201 (Created) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `params` - Request parameters, must include a "user" key with user attributes

  ## Request Body Example

      {
        "user": {
          "username": "john_doe",
          "email": "john@example.com",
          "password": "secure_password"
        }
      }

  ## Response Example (Success)

      {
        "data": {
          "user": {
            "id": 1,
            "username": "john_doe",
            "email": "john@example.com",
            "guest": false,
            "inserted_at": "2024-11-02T10:30:00Z",
            "updated_at": "2024-11-02T10:30:00Z"
          },
          "token": "eyJhbGc..."
        }
      }

  ## Response Example (Error)

      {
        "errors": [
          {
            "code": "username",
            "title": "Username",
            "detail": "has already been taken"
          }
        ]
      }
  """
  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, %{"user" => user_params} = params) do
    user_params = Map.put(user_params, "friend_slug", params["friend_slug"])

    with {:ok, declaration} <- AgeTerms.parse(params),
         {:ok, registered} <- Auth.register_user(user_params),
         {:ok, user} <- AgeTerms.store(registered, declaration) do
      token = Token.generate(user)
      Auth.touch_last_seen(user)

      conn
      |> put_status(:created)
      |> put_view(UserJSON)
      |> render(:show, %{user: user, token: token, linked_friend: registered.linked_friend})
    end
  end

  operation(:login,
    summary: "Authenticate a user",
    description: """
    Authenticates a user by verifying their credentials. The `username` field
    accepts either the account's username or its email address (an identifier
    containing `@` is matched against the email, case-insensitively). Returns
    the user data along with a JWT authentication token on success.

    The token should be included in subsequent requests in the Authorization header
    as a Bearer token: `Authorization: Bearer <token>`

    ## Error Responses
    - Returns 401 Unauthorized if credentials are invalid (a guest without a
      password is invalid too)
    """,
    request_body: {"Login credentials", "application/json", UserSchemas.LoginRequest},
    responses: [
      ok: {"Authentication successful", "application/json", UserSchemas.UserWithTokenResponse},
      unauthorized:
        {"Invalid credentials", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Authenticate a user and retrieve a token.

  Authenticates a user by verifying their username and password. On successful
  authentication, generates an authentication token and returns the user data
  along with the token.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `params` - Request parameters, must include "username" and "password" keys

  ## Request Body Example

      {
        "username": "john_doe",
        "password": "secure_password"
      }

  ## Response Example (Success)

      {
        "data": {
          "user": {
            "id": 1,
            "username": "john_doe",
            "email": "john@example.com",
            "guest": false,
            "inserted_at": "2024-11-02T10:30:00Z",
            "updated_at": "2024-11-02T10:30:00Z"
          },
          "token": "eyJhbGc..."
        }
      }

  ## Response Example (Error)

      {
        "errors": [
          {
            "code": "INVALID_CREDENTIALS",
            "title": "Invalid credentials",
            "detail": "Username or password is incorrect"
          }
        ]
      }
  """
  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, %{"username" => username, "password" => password} = params) do
    with {:ok, declaration} <- AgeTerms.parse(params),
         {:ok, user} <- Auth.authenticate_user(username, password),
         {:ok, user} <- AgeTerms.store(user, declaration) do
      token = Token.generate(user)
      Auth.touch_last_seen(user)

      conn
      |> put_view(UserJSON)
      |> render(:show, %{user: user, token: token})
    end
  end

  operation(:apple,
    summary: "Sign in with Apple",
    description:
      "Signs in a linked account, returns an install-bound Classic claim when the verified email matches Classic, or creates a new provider account. `install_id` is required only for a Classic match.",
    request_body: {"Apple identity token", "application/json", ClassicClaimSchemas.AppleRequest},
    responses: [
      ok:
        {"Authentication successful or Classic account found", "application/json",
         ClassicClaimSchemas.ProviderSignInResponse},
      unauthorized: {"Invalid identity", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      unprocessable_entity:
        {"Missing Classic binding or invalid generated account data", "application/json",
         ErrorSchemas.validation_error()},
      service_unavailable:
        {"Provider or Classic verification unavailable", "application/json",
         ErrorSchemas.error_response()}
    ]
  )

  def apple(conn, %{"identity_token" => token} = params),
    do: provider_login(conn, :apple, token, params)

  def apple(_conn, _params), do: {:error, :invalid_credentials}

  operation(:facebook,
    summary: "Sign in with Facebook",
    description:
      "Accepts either a Graph `access_token` or a Limited Login `authentication_token` plus `nonce`. Signs in a linked account, returns an install-bound Classic claim when the Facebook ID, business ID, or verified email matches Classic, or creates a new provider account. `install_id` is required only for a Classic match.",
    request_body:
      {"Facebook credential", "application/json", ClassicClaimSchemas.FacebookRequest},
    responses: [
      ok:
        {"Authentication successful or Classic account found", "application/json",
         ClassicClaimSchemas.ProviderSignInResponse},
      unauthorized: {"Invalid identity", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      unprocessable_entity:
        {"Missing Classic binding or invalid generated account data", "application/json",
         ErrorSchemas.validation_error()},
      service_unavailable:
        {"Provider or Classic verification unavailable", "application/json",
         ErrorSchemas.error_response()}
    ]
  )

  def facebook(conn, params) do
    with {:ok, credential} <- FacebookCredential.parse(params) do
      provider_login(conn, :facebook, credential, params)
    end
  end

  defp provider_login(conn, provider, provider_token, params) do
    with {:ok, declaration} <- AgeTerms.parse(params) do
      provider_login(conn, provider, provider_token, params, declaration)
    end
  end

  defp provider_login(conn, provider, provider_token, params, declaration) do
    case ProviderAuth.authenticate(provider, provider_token, params) do
      {:ok, authenticated} ->
        with {:ok, user} <- AgeTerms.store(authenticated, declaration) do
          token = Token.generate(user)
          Auth.touch_last_seen(user)

          conn
          |> put_view(UserJSON)
          |> render(:show, %{user: user, token: token, linked_friend: authenticated.linked_friend})
        end

      {:classic_found, result} ->
        json(conn, %{data: Map.put(result, :classic_found, true)})

      {:error, reason} ->
        {:error, reason}
    end
  end

  operation(:guest,
    summary: "Create a guest account",
    description: """
    Creates a `guest: true` account with a generated username, either directly
    or for an invitation. A supplied invite is always validated and must be
    neither `revoked` nor `expired` (410 otherwise); any other state still
    creates the guest and is returned as `state`.

    Direct creation requires a random `creation_token`. Retrying that token
    returns the same guest with a fresh authentication token, so a lost response
    does not create another player. Invitation clients may also supply one;
    omitting it keeps the existing create-on-every-call behavior.

    When omitted or null, the server generates a friendly two-word display
    name. A supplied display name is NFKC-normalized and trimmed, is 2-20
    graphemes, and must not look like the name of a player connected at the
    invite's table (casefolded, diacritics and non-alphanumerics removed); held
    seats are excluded so a returning guest can reuse her own name. Violations
    answer 422 on `display_name`.

    Limited at policies `guest_create` and `guest_create_daily` (per client IP)
    and `guest_create_install` (per `install_id`; skipped without one).
    """,
    request_body: {"Guest creation data", "application/json", UserSchemas.GuestRequest},
    responses: [
      created: {"Guest created", "application/json", UserSchemas.GuestResponse},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      not_found: {"Unknown invite code", "application/json", ErrorSchemas.not_found_error()},
      conflict:
        {"Creation token belongs to an upgraded account", "application/json",
         ErrorSchemas.conflict_error()},
      gone: {"Invite revoked or expired", "application/json", ErrorSchemas.gone_error()},
      unprocessable_entity:
        {"Invalid display name or platform", "application/json", ErrorSchemas.validation_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Creates a direct or invited guest account and answers 201 with the user and
  token. Invited responses also include the invite's state.
  """
  @spec guest(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def guest(conn, params) do
    with {:ok, declaration} <- AgeTerms.parse(params),
         {:ok, platform} <- parse_platform(params["platform"]),
         {:ok, invite} <- guest_invite(params),
         {:ok, creation_token} <- creation_token(params, invite),
         {:ok, state} <- guest_state(invite),
         {:ok, user, created?} <-
           Auth.create_guest_user_once(
             guest_attrs(params, creation_token),
             taken_name_keys(invite)
           ),
         {:ok, user} <- AgeTerms.store(user, declaration) do
      token = Token.generate(user)
      Auth.touch_last_seen(user)

      log_guest_created(invite, user, platform, created?)

      conn
      |> put_status(:created)
      |> put_view(UserJSON)
      |> render_guest(user, token, state)
    end
  end

  operation(:upgrade,
    summary: "Upgrade the calling guest to a registered account",
    description: """
    Sets email, password and an optional username on the guest's own row, so
    every game, rating and achievement stays attached (KD4). Every token issued
    before the upgrade is revoked; the response carries a fresh one. Open
    sockets stay connected.

    A registered caller answers 409 `NOT_A_GUEST`; an email in use
    (case-insensitive) 409 `EMAIL_TAKEN`; a username in use 409
    `USERNAME_TAKEN`; invalid fields 422. Limited at policy `auth_upgrade`
    (per client IP).
    """,
    security: [%{"bearer_auth" => []}],
    request_body: {"Upgrade data", "application/json", UserSchemas.UpgradeRequest},
    responses: [
      ok: {"Upgraded", "application/json", UserSchemas.UserWithTokenResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      conflict:
        {"Not a guest, or email or username taken", "application/json",
         ErrorSchemas.conflict_error()},
      unprocessable_entity:
        {"Validation errors", "application/json", ErrorSchemas.validation_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Upgrades the calling guest in place (R13) and answers the user with a token
  minted from the upgraded row, so it carries the bumped `token_version`.
  """
  @spec upgrade(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upgrade(conn, params) do
    user = conn.assigns[:current_user]

    with {:ok, declaration} <- AgeTerms.parse(params),
         {:ok, upgraded} <- Auth.upgrade_guest(user, upgrade_attrs(params)),
         {:ok, declared} <- AgeTerms.store(upgraded, declaration) do
      Invites.record_upgrade(declared.id)
      Auth.touch_last_seen(declared)
      token = Token.generate(declared)

      conn
      |> put_view(UserJSON)
      |> render(:show, %{user: declared, token: token, linked_friend: upgraded.linked_friend})
    end
  end

  operation(:delete_me,
    summary: "Delete the calling account",
    description: """
    Leaves the caller's room, revokes the invites they host, deletes their
    profile, achievement and invite rows together with the account, and
    disconnects their sockets. Game records keep the bare user id, which then
    resolves to nobody (KD9). Feedback they sent stays, without a reply
    address.
    """,
    security: [%{"bearer_auth" => []}],
    responses: [
      no_content: {"Account deleted", "application/json", %OpenApiSpex.Schema{type: :object}},
      unauthorized: {"Unauthorized", "application/json", ErrorSchemas.unauthorized_error()},
      unprocessable_entity:
        {"The account could not be deleted", "application/json", ErrorSchemas.validation_error()}
    ]
  )

  @doc """
  Deletes the calling account with the shared recipe `Auth.delete_user/1` (R15).
  """
  @spec delete_me(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_me(conn, _params) do
    user = conn.assigns[:current_user]

    with {:ok, _deleted} <- Auth.delete_user(user) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:request_password_reset,
    summary: "Request a password reset link",
    description: """
    Sends a password reset link when an account matches the identifier (username
    or email). The response is identical whether or not the account exists, and
    the mail goes out after it.

    Rate limited per client IP and, additionally, per normalized identifier.
    """,
    request_body:
      {"Password reset request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           identifier: %OpenApiSpex.Schema{
             type: :string,
             description: "Username or email address of the account"
           }
         },
         required: [:identifier]
       }},
    responses: [
      ok:
        {"Request accepted", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               properties: %{message: %OpenApiSpex.Schema{type: :string}}
             }
           }
         }},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Request a password reset link.
  """
  @spec request_password_reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_password_reset(conn, %{"identifier" => identifier}) do
    with {:ok, reset} <- Auth.request_password_reset(identifier) do
      maybe_log_debug_password_reset(reset)

      conn =
        conn
        |> put_status(:ok)
        |> json(%{data: password_reset_request_response(reset)})

      maybe_deliver_password_reset(reset)
      conn
    end
  end

  def request_password_reset(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{data: password_reset_request_response(nil)})
  end

  operation(:reset_password,
    summary: "Reset a password with a reset token",
    description: """
    Sets a new password for the account the reset token belongs to and returns
    the user with a fresh authentication token. Rate limited per client IP.
    """,
    request_body:
      {"Password reset confirmation", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           token: %OpenApiSpex.Schema{type: :string, description: "Reset token from the link"},
           password: %OpenApiSpex.Schema{
             type: :string,
             format: :password,
             description: "New password (minimum 8 characters)"
           }
         },
         required: [:token, :password]
       }},
    responses: [
      ok: {"Password reset", "application/json", UserSchemas.UserWithTokenResponse},
      unprocessable_entity:
        {"Invalid or expired reset token", "application/json", ErrorSchemas.validation_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Reset a password using a reset token.

  `Auth.reset_user_password/2` changes the password, clears the reset token
  and bumps `token_version` in one transaction. The token in the response is
  minted from the user that transaction returns, so it carries the new
  version while every token issued before the reset is revoked.
  """
  @spec reset_password(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset_password(conn, %{"token" => token, "password" => password}) do
    with {:ok, user} <- Auth.reset_user_password(token, password) do
      token = Token.generate(user)

      conn
      |> put_view(UserJSON)
      |> render(:show, %{user: user, token: token})
    end
  end

  operation(:me,
    summary: "Get current authenticated user",
    description: """
    Retrieves the current authenticated user's profile information.

    This endpoint requires authentication. The Bearer token must be included
    in the Authorization header: `Authorization: Bearer <token>`

    The current user is loaded by the authentication middleware and available
    in the request context.

    ## Error Responses
    - Returns 401 Unauthorized if token is missing, invalid, or expired
    """,
    security: [%{"bearer_auth" => []}],
    responses: [
      ok: {"Current user retrieved successfully", "application/json", UserSchemas.UserResponse},
      unauthorized:
        {"Authentication required or invalid", "application/json",
         ErrorSchemas.unauthorized_error()},
      service_unavailable:
        {"Player eligibility could not be checked", "application/json",
         ErrorSchemas.error_response()}
    ]
  )

  @doc """
  Retrieve the current authenticated user.

  Returns the authenticated user's data. Requires a valid Bearer token
  in the Authorization header. The current user is loaded via the
  Authenticate plug and available in `conn.assigns[:current_user]`.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned)
    * `_params` - Request parameters (unused)

  ## Headers Required

      Authorization: Bearer <token>

  ## Response Example (Success)

      {
        "data": {
          "user": {
            "id": 1,
            "username": "john_doe",
            "email": "john@example.com",
            "guest": false,
            "inserted_at": "2024-11-02T10:30:00Z",
            "updated_at": "2024-11-02T10:30:00Z"
          }
        }
      }

  ## Response Example (Error - No Auth)

      {
        "errors": [
          {
            "code": "UNAUTHORIZED",
            "title": "Unauthorized",
            "detail": "Authentication required"
          }
        ]
      }
  """
  @spec me(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, :profile_unavailable}
  def me(conn, _params) do
    user = conn.assigns[:current_user]

    conn
    |> put_view(UserJSON)
    |> render(:show, %{
      user: user,
      seat_invitations: PidroServer.Games.RoomManager.seat_invitations(user.id)
    })
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Block lookup failed: #{Exception.message(error)}")
      {:error, :profile_unavailable}
  end

  operation(:age,
    summary: "Declare the calling user's age band and accepted terms",
    description:
      "Records the declaration once for an account whose age band is still unknown. The age band cannot be changed after it is stored.",
    security: [%{"bearer_auth" => []}],
    request_body: {"Age and terms declaration", "application/json", UserSchemas.AgeRequest},
    responses: [
      ok: {"Declaration stored", "application/json", UserSchemas.UserResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      conflict: {"Age already set", "application/json", ErrorSchemas.conflict_error()},
      unprocessable_entity:
        {"Validation errors", "application/json", ErrorSchemas.validation_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @spec age(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def age(conn, params) do
    with {:ok, declaration} <- AgeTerms.parse(params, required: true),
         {:ok, user} <- AgeTerms.declare(conn.assigns.current_user, declaration) do
      conn
      |> put_view(UserJSON)
      |> render(:show, %{user: user})
    end
  end

  # ==================== Guest and upgrade helpers ====================

  # `revoked` and `expired` refuse guest creation (R10); every other state is
  # returned to the client so it can show the table's situation.
  defp guest_invite(params) do
    case Map.fetch(params, "invite_code") do
      :error -> {:ok, nil}
      {:ok, code} -> Invites.get_by_code(code)
    end
  end

  defp creation_token(%{"creation_token" => token}, nil)
       when is_binary(token) and byte_size(token) == 36 do
    case Ecto.UUID.cast(token) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        invalid_creation_token()
    end
  end

  defp creation_token(_params, nil), do: invalid_creation_token()

  defp creation_token(params, %Invite{}) do
    case params["creation_token"] do
      nil -> {:ok, nil}
      token -> creation_token(%{"creation_token" => token}, nil)
    end
  end

  defp invalid_creation_token do
    changeset =
      {%{}, %{creation_token: :string}}
      |> Ecto.Changeset.cast(%{}, [])
      |> Ecto.Changeset.add_error(:creation_token, "must be a UUID")

    {:error, changeset}
  end

  defp guest_state(nil), do: {:ok, nil}

  defp guest_state(%Invite{} = invite) do
    case InviteController.derive_state(invite) do
      state when state in [:revoked, :expired] -> InviteController.state_error(state, invite)
      state -> {:ok, state}
    end
  end

  defp guest_attrs(params, creation_token) do
    %{
      display_name: params["display_name"],
      install_id: params["install_id"],
      creation_token: creation_token
    }
  end

  defp upgrade_attrs(%{"user" => user_params} = params) when is_map(user_params),
    do: user_params |> upgrade_attrs() |> Map.put("friend_slug", params["friend_slug"])

  defp upgrade_attrs(params) when is_map(params) do
    Map.take(params, ["email", "password", "username", "friend_slug"])
  end

  # The look-alike keys of the players connected at the invite's table (R11):
  # `:connected` human seats only, so a held seat's name can be reused by its
  # returning owner. Empty when the room is gone.
  defp taken_name_keys(nil), do: []

  defp taken_name_keys(%Invite{room_code: room_code, room_id: room_id}) do
    case RoomManager.get_room(room_code) do
      {:ok, %Room{id: ^room_id, seats: seats}} ->
        seats
        |> Map.values()
        |> Enum.filter(&connected_human?/1)
        |> Enum.map(& &1.user_id)
        |> Auth.get_users_map()
        |> Map.values()
        |> Enum.map(&User.name_key(&1.display_name || &1.username))

      _other ->
        []
    end
  end

  defp connected_human?(%Seat{occupant_type: :human, status: :connected, user_id: id}),
    do: is_binary(id)

  defp connected_human?(_seat), do: false

  defp log_guest_created(%Invite{} = invite, user, platform, :created) do
    InviteController.log_event(invite, %{
      kind: "guest_created",
      user_id: user.id,
      platform: platform
    })
  end

  defp log_guest_created(_invite, _user, _platform, _created?), do: :ok

  defp render_guest(conn, user, token, nil), do: render(conn, :show, %{user: user, token: token})

  defp render_guest(conn, user, token, state),
    do: render(conn, :guest, %{user: user, token: token, state: state})

  defp parse_platform(nil), do: {:ok, nil}
  defp parse_platform(platform) when platform in @platforms, do: {:ok, platform}

  defp parse_platform(platform) do
    changeset =
      {%{}, %{platform: :string}}
      |> Ecto.Changeset.cast(%{"platform" => platform}, [:platform])
      |> Ecto.Changeset.validate_inclusion(:platform, @platforms)

    {:error, changeset}
  end

  defp password_reset_request_response(reset) do
    response = %{
      message: "If an account exists for that username or email, a reset link has been sent."
    }

    if expose_debug_password_reset?() && reset do
      Map.merge(response, %{
        reset_token: reset.token,
        reset_url: password_reset_url(reset.token)
      })
    else
      response
    end
  end

  defp maybe_deliver_password_reset(nil), do: :ok

  defp maybe_deliver_password_reset(%{user: %{email: email} = user, token: token})
       when is_binary(email) and email != "" do
    # Sent after the answer: neither its time nor its outcome may tell a known
    # address from an unknown one. `deliver_logged/2` catches every failure, so
    # the task never crashes with the mail in its exit reason.
    Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
      Emails.transactional_email(:password_reset, {user.username || email, email}, %{
        username: if(String.trim(user.username || "") == "", do: "there", else: user.username),
        reset_url: password_reset_url(token)
      })
      |> Mailer.deliver_logged("Password reset")
    end)

    :ok
  end

  defp maybe_deliver_password_reset(_reset), do: :ok

  defp maybe_log_debug_password_reset(nil), do: :ok

  defp maybe_log_debug_password_reset(%{user: user, token: token}) do
    if expose_debug_password_reset?() do
      Logger.warning("DEV PASSWORD RESET LINK for #{user.username}: #{password_reset_url(token)}")
    end

    :ok
  end

  defp password_reset_url(token) do
    base_url =
      :pidro_server
      |> Application.get_env(:password_reset, [])
      |> Keyword.get(:reset_url_base, System.get_env("WEB_URL") || "http://localhost:5173")

    "#{String.trim_trailing(base_url, "/")}/reset-password?token=#{URI.encode_www_form(token)}"
  end

  defp expose_debug_password_reset? do
    :pidro_server
    |> Application.get_env(:password_reset, [])
    |> Keyword.get(:debug_tokens, false)
  end
end

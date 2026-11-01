defmodule PidroServer.Accounts.Auth do
  @moduledoc """
  The Auth context for user authentication and retrieval operations.

  This module provides functions for user registration, authentication, and user lookups.
  It handles password hashing using Bcrypt and interacts with the database through
  PidroServer.Repo.

  ## Token revocation

  Every token carries the user's `token_version` at mint time (see
  `PidroServer.Accounts.Token`). `fetch_user_for_token/1` is the one place
  that compares a token's version with the database; the `Authenticate` plug
  and `UserSocket.connect/3` both go through it. `bump_token_version/1`
  increments the version atomically, which invalidates every earlier token,
  and then broadcasts `"disconnect"` on `"user_socket:<id>"` so live sockets
  close. A password reset bumps the version in the same transaction as the
  password change.

  ## Guests

  `create_guest_user/2` builds a `guest: true` row with a generated
  `guest_<code>` username and rejects a display name whose
  `User.name_key/1` is in the caller's taken list (R10, R11).
  `create_guest_user_once/2` additionally deduplicates retries carrying the
  same opaque creation token.
  `upgrade_guest/2` turns that row into a registered account in place and
  bumps `token_version` without a disconnect broadcast, so the guest's open
  socket survives while every older token dies (R13, KTD7).

  ## Deletion

  `delete_user/1` is the deletion recipe (KTD8) shared by
  `DELETE /api/v1/auth/me` and the admin panel: it revokes
  the invites they host, deletes their personal rows and the user row in one
  database transaction, then performs the in-memory room cleanup and
  broadcasts the disconnect after commit. The guest reaper uses
  `delete_guest/1`, which locks and reloads the account before applying the
  same recipe so it cannot delete a concurrently upgraded account.
  `game_stats` and `abandonment_events` keep the bare id (KD9).

  ## Last seen

  `touch_last_seen/1` writes `last_seen_at` at most once per hour per user
  (R16). Callers minting a token or accepting a socket connect call it.

  ## Examples

      # Register a new user
      iex> PidroServer.Accounts.Auth.register_user(%{
      ...>   username: "john_doe",
      ...>   email: "john@example.com",
      ...>   password: "secure_password"
      ...> })
      {:ok, %PidroServer.Accounts.User{}}

      # Authenticate a user
      iex> PidroServer.Accounts.Auth.authenticate_user("john_doe", "secure_password")
      {:ok, %PidroServer.Accounts.User{}}

      # Get user by ID
      iex> PidroServer.Accounts.Auth.get_user(1)
      %PidroServer.Accounts.User{} | nil

      # Get user by username
      iex> PidroServer.Accounts.Auth.get_user_by_username("john_doe")
      %PidroServer.Accounts.User{} | nil
  """

  import Ecto.Query
  require Logger

  alias Ecto.Changeset
  alias PidroServer.Accounts
  alias PidroServer.Accounts.{Avatars, ClassicNameReservations, GuestNames, Token}
  alias PidroServer.Accounts.User
  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Invites
  alias PidroServer.Invites.{Codes, Event, Invite, Redemption}
  alias PidroServer.Moderation
  alias PidroServer.Profiles
  alias PidroServer.Profiles.{Achievement, GameXp, PlayerProfile}
  alias PidroServer.Progression
  alias PidroServer.Repo

  @default_user_page_size 30
  @password_reset_token_bytes 32
  @guest_username_prefix "guest_"
  @guest_username_attempts 2
  @last_seen_min_interval_seconds 60 * 60

  @doc """
  Registers a new user with the given attributes.

  Expects a map with at least the following keys:
    - `:username` (string) - The user's username
    - `:email` (string) - The user's email address
    - `:password` (string) - The user's password (will be hashed)

  ## Returns

    - `{:ok, user}` - User was successfully created
    - `{:error, changeset}` - Validation or database error

  ## Examples

      iex> PidroServer.Accounts.Auth.register_user(%{
      ...>   username: "jane_doe",
      ...>   email: "jane@example.com",
      ...>   password: "secure_pass123"
      ...> })
      {:ok, %PidroServer.Accounts.User{id: 1, username: "jane_doe"}}

      iex> PidroServer.Accounts.Auth.register_user(%{username: "jane_doe"})
      {:error, %Ecto.Changeset{}}
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> moderate_username()
    |> Accounts.validate_public_name_changes([:username, :display_name])
    |> ClassicNameReservations.validate_changes()
    |> Repo.insert()
    |> PidroServer.Friends.link_signup(fetch_attr(attrs, :friend_slug))
  end

  @doc """
  Creates a guest account (R10, R11).

  Reads the optional `display_name` and `install_id` from `attrs` (atom or
  string keys), generates a public name when none is supplied, and generates
  the username as `guest_` plus a
  `PidroServer.Invites.Codes` code, inserts with `User.guest_changeset/2` and
  redraws once when the username is taken (KTD2). `taken_name_keys` are the
  `User.name_key/1` values of the players connected at the invite's table;
  a display name whose key is among them is rejected on `display_name`.

  `opts[:generator]` replaces `Codes.generate/0`, which is how tests force a
  collision.

  ## Returns

    - `{:ok, user}` - The guest row
    - `{:error, changeset}` - Invalid display name, a taken look-alike name,
      or both username draws collided
  """
  @spec create_guest_user(map(), [String.t()], keyword()) ::
          {:ok, User.t()} | {:error, Changeset.t()}
  def create_guest_user(attrs, taken_name_keys, opts \\ [])
      when is_map(attrs) and is_list(taken_name_keys) and is_list(opts) do
    generator = Keyword.get(opts, :generator, &Codes.generate/0)

    with {:ok, attrs} <- ensure_guest_display_name(guest_attrs(attrs)) do
      insert_guest(attrs, taken_name_keys, generator, @guest_username_attempts)
    end
  end

  @doc """
  Creates a guest once for an opaque creation token.

  A repeated token returns the original guest instead of minting another
  player. The token is hashed before storage and is never returned. Calls
  without a token retain the original create-on-every-call behavior for older
  invitation clients.
  """
  @spec create_guest_user_once(map(), [String.t()], keyword()) ::
          {:ok, User.t(), :created | :existing} | {:error, Changeset.t() | :creation_conflict}
  def create_guest_user_once(attrs, taken_name_keys, opts \\ [])
      when is_map(attrs) and is_list(taken_name_keys) and is_list(opts) do
    case creation_token_hash(attrs) do
      nil ->
        with {:ok, user} <- create_guest_user(attrs, taken_name_keys, opts) do
          {:ok, user, :created}
        end

      token_hash ->
        case guest_by_creation_token(token_hash) do
          %User{} = user ->
            {:ok, user, :existing}

          nil ->
            attrs = Map.put(attrs, :guest_creation_token_hash, token_hash)

            case create_guest_user(attrs, taken_name_keys, opts) do
              {:ok, user} ->
                {:ok, user, :created}

              {:error, changeset} ->
                recover_guest_retry(changeset, token_hash)
            end
        end
    end
  end

  @doc """
  Authenticates a user by an identifier and password (R14, KTD14).

  An identifier containing `@` is looked up by `lower(email)` only; any
  other identifier by exact username only, so a username shaped like
  someone else's email can never shadow that email at login.

  A miss, and a user without a `password_hash` (a guest), run a dummy
  Bcrypt verify so the response time matches a real check, then answer
  invalid credentials.

  ## Returns

    - `{:ok, user}` - Credentials are valid
    - `{:error, :invalid_credentials}` - No such user, wrong password, or the
      account has no password

  ## Examples

      iex> PidroServer.Accounts.Auth.authenticate_user("jane_doe", "secure_pass123")
      {:ok, %PidroServer.Accounts.User{username: "jane_doe"}}

      iex> PidroServer.Accounts.Auth.authenticate_user("jane@example.com", "secure_pass123")
      {:ok, %PidroServer.Accounts.User{username: "jane_doe"}}

      iex> PidroServer.Accounts.Auth.authenticate_user("jane_doe", "wrong_password")
      {:error, :invalid_credentials}
  """
  @spec authenticate_user(term(), term()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_user(identifier, password)
      when is_binary(identifier) and is_binary(password) do
    case get_user_for_login(identifier) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      _missing_or_passwordless ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def authenticate_user(_identifier, _password) do
    Bcrypt.no_user_verify()
    {:error, :invalid_credentials}
  end

  @doc """
  Fetches a user by their ID.

  ## Returns

    - `user` - The user struct if found
    - `nil` - If no user with the given ID exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user(1)
      %PidroServer.Accounts.User{id: 1}

      iex> PidroServer.Accounts.Auth.get_user(999)
      nil
  """
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc """
  Fetches a user by their ID.

  Raises `Ecto.NoResultsError` if no user with the given ID exists.

  ## Returns

    - `user` - The user struct if found

  ## Raises

    - `Ecto.NoResultsError` - If no user with the given ID exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user!(1)
      %PidroServer.Accounts.User{id: 1}

      iex> PidroServer.Accounts.Auth.get_user!(999)
      ** (Ecto.NoResultsError) expected at least one result but got none
  """
  def get_user!(id) do
    Repo.get!(User, id)
  end

  @doc "Updates only the biography of the identified user."
  def update_bio(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> user |> User.bio_changeset(attrs) |> Repo.update()
    end
  end

  @doc "Returns the exact public identity allowlist for a user."
  def public_profile(user_id) when is_binary(user_id) do
    with {:ok, id} <- Ecto.UUID.cast(user_id),
         %User{} = user <- Repo.get(User, id) do
      {:ok, public_identity(user)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Returns `public_profile/1` for the user a share link names."
  def public_profile_by_slug(slug) when is_binary(slug) do
    case get_user_by_share_slug(slug) do
      %User{} = user -> {:ok, public_identity(user)}
      nil -> {:error, :not_found}
    end
  end

  @doc "Gets the user a share slug names, or nil."
  @spec get_user_by_share_slug(String.t()) :: User.t() | nil
  def get_user_by_share_slug(slug) when is_binary(slug), do: Repo.get_by(User, share_slug: slug)

  defp public_identity(user) do
    %{
      user_id: user.id,
      username: user.username,
      display_name: user.display_name,
      avatar_url: PidroServer.Accounts.Avatars.url(Avatars.metadata_for(user.id), user.id),
      bio: user.bio
    }
  end

  @doc """
  Loads the user a verified token belongs to and checks the token version.

  This is the single place that compares a token's `v` claim with
  `users.token_version`; both the `Authenticate` plug and
  `UserSocket.connect/3` call it. A token minted before the last
  `bump_token_version/1` is reported as revoked.

  ## Returns

    - `{:ok, user}` - The user exists and the token version matches
    - `{:error, :not_found}` - No user with that id exists
    - `{:error, :token_revoked}` - The user's `token_version` has moved on

  ## Examples

      iex> {:ok, claims} = PidroServer.Accounts.Token.verify(token)
      iex> PidroServer.Accounts.Auth.fetch_user_for_token(claims)
      {:ok, %PidroServer.Accounts.User{}}
  """
  @spec fetch_user_for_token(Token.claims()) ::
          {:ok, User.t()} | {:error, :not_found | :token_revoked}
  def fetch_user_for_token(%{id: id, v: v}) when is_binary(id) and is_integer(v) do
    case get_user(id) do
      nil -> {:error, :not_found}
      %User{token_version: ^v} = user -> {:ok, user}
      %User{} -> {:error, :token_revoked}
    end
  end

  @doc """
  Increments the user's `token_version` atomically and disconnects their sockets.

  Phase 0 ships this without a production caller: `reset_user_password/2`
  runs the same increment inside its own transaction. The account upgrade,
  delete and logout flows of later phases call it directly.

  Every token minted before the increment fails `fetch_user_for_token/1`
  afterwards. Once the increment has committed, `"disconnect"` is broadcast
  on `"user_socket:<id>"`, which closes the user's live socket connections;
  a client still holding the old token then fails every reconnect until it
  logs in again.

  Accepts a `%User{}` or a bare user id.

  ## Returns

    - `{:ok, user}` - The user with the new `token_version`
    - `{:error, :not_found}` - No user with that id exists

  ## Examples

      iex> PidroServer.Accounts.Auth.bump_token_version(user)
      {:ok, %PidroServer.Accounts.User{token_version: 1}}
  """
  @spec bump_token_version(User.t() | String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def bump_token_version(%User{id: id}), do: bump_token_version(id)

  def bump_token_version(id) when is_binary(id) do
    with {:ok, user} <- increment_token_version(Repo, id) do
      broadcast_disconnect(user)
      {:ok, user}
    end
  end

  @doc """
  Upgrades a guest into a registered account in place (R13, KTD7).

  Reads `email`, `password` and an optional `username` from `attrs` (atom
  or string keys). The email is pre-checked case-insensitively and the
  username exactly; then `User.upgrade_changeset/2` and the `token_version`
  increment run in one transaction, and the returned struct carries the new
  version so a token minted from it is valid. A unique-constraint failure
  in the race between the pre-check and the commit maps to the same atoms.

  No disconnect is broadcast: the guest's open socket stays connected while
  every token minted before the upgrade is revoked.

  ## Returns

    - `{:ok, user}` - The upgraded row with the bumped `token_version`
    - `{:error, :not_a_guest}` - The user is already registered
    - `{:error, :email_taken}` - Another account has that email (any case)
    - `{:error, :username_taken}` - Another account has that username
    - `{:error, changeset}` - Invalid attributes; nothing was written
  """
  @spec upgrade_guest(User.t(), map()) ::
          {:ok, User.t()}
          | {:error, :not_a_guest | :email_taken | :username_taken | Changeset.t()}
  def upgrade_guest(%User{guest: false}, _attrs), do: {:error, :not_a_guest}

  def upgrade_guest(%User{guest: true, id: id}, attrs) when is_map(attrs) do
    friend_slug = fetch_attr(attrs, :friend_slug)
    attrs = upgrade_attrs(attrs)

    with :ok <- ensure_email_free(Map.get(attrs, :email), id),
         :ok <- ensure_username_free(Map.get(attrs, :username), id) do
      Repo.transaction(fn ->
        guest = Repo.one!(from u in User, where: u.id == ^id, lock: "FOR UPDATE")
        if not guest.guest, do: Repo.rollback(:not_a_guest)

        result =
          guest
          |> User.upgrade_changeset(attrs)
          |> moderate_username(guest.classic_user_id)
          |> Accounts.validate_public_name_changes([:username])
          |> ClassicNameReservations.validate_changes(guest.classic_user_id)
          |> update_and_bump_version()

        case result do
          {:ok, user} -> user
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> map_upgrade_result()
      |> PidroServer.Friends.link_signup(friend_slug)
    end
  end

  @doc """
  Records that the user was seen, at most once per hour (R16, KTD15).

  One `update_all` guarded by `last_seen_at IS NULL OR last_seen_at < now()
  - 1 hour`, so a busy user costs one write per hour rather than one per
  request. Accepts a `%User{}` or a bare user id; an unknown id is a no-op.
  """
  @spec touch_last_seen(User.t() | String.t()) :: :ok
  def touch_last_seen(%User{id: id}), do: touch_last_seen(id)

  def touch_last_seen(id) when is_binary(id) do
    now = DateTime.utc_now()
    stale_before = DateTime.add(now, -@last_seen_min_interval_seconds, :second)

    query =
      from u in User,
        where: u.id == ^id and (is_nil(u.last_seen_at) or u.last_seen_at < ^stale_before)

    Repo.update_all(query, set: [last_seen_at: now])
    :ok
  end

  @doc """
  Fetches a user by their username.

  ## Returns

    - `user` - The user struct if found
    - `nil` - If no user with the given username exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user_by_username("jane_doe")
      %PidroServer.Accounts.User{username: "jane_doe"}

      iex> PidroServer.Accounts.Auth.get_user_by_username("nonexistent")
      nil
  """
  def get_user_by_username(username) do
    Repo.one(from u in User, where: u.username == ^username)
  end

  @doc """
  Fetches a user by their email address.

  ## Returns

    - `user` - The user struct if found
    - `nil` - If no user with the given email exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user_by_email("jane@example.com")
      %PidroServer.Accounts.User{email: "jane@example.com"}

      iex> PidroServer.Accounts.Auth.get_user_by_email("nonexistent@example.com")
      nil
  """
  def get_user_by_email(email) do
    Repo.one(from u in User, where: u.email == ^email)
  end

  @doc """
  Requests a password reset for a username or email address.

  Returns `{:ok, nil}` when the account does not exist so callers can avoid
  account enumeration. When a user is found, stores a hashed reset token and
  returns the raw token for delivery.
  """
  def request_password_reset(identifier) when is_binary(identifier) do
    case get_user_by_username_or_email(identifier) do
      nil ->
        {:ok, nil}

      %User{} = user ->
        token = generate_password_reset_token()
        token_hash = hash_password_reset_token(token)

        with {:ok, user} <-
               user
               |> User.password_reset_changeset(%{
                 password_reset_token_hash: token_hash,
                 password_reset_sent_at: DateTime.utc_now()
               })
               |> Repo.update() do
          {:ok, %{user: user, token: token}}
        end
    end
  end

  def request_password_reset(_identifier), do: {:ok, nil}

  @doc """
  Resets a user's password with a valid password-reset token.

  The password change, the clearing of `password_reset_token_hash` and
  `password_reset_sent_at`, and the `token_version` increment run in one
  transaction, so a reset link cannot be replayed and every token minted
  before the reset is revoked. The returned user reflects the committed row,
  so a token minted from it carries the new version. The disconnect
  broadcast fires only after the transaction has committed.

  ## Returns

    - `{:ok, user}` - The updated user
    - `{:error, %Ecto.Changeset{}}` - The new password is invalid
    - `{:error, :invalid_or_expired_password_reset_token}` - No live reset
      token matches
  """
  def reset_user_password(token, password) when is_binary(token) and is_binary(password) do
    token_hash = hash_password_reset_token(token)

    cutoff =
      DateTime.add(
        DateTime.utc_now(),
        -Application.fetch_env!(:pidro_server, :password_reset_ttl_seconds),
        :second
      )

    query =
      from u in User,
        where: u.password_reset_token_hash == ^token_hash,
        where: u.password_reset_sent_at > ^cutoff

    case Repo.one(query) do
      nil ->
        {:error, :invalid_or_expired_password_reset_token}

      %User{} = user ->
        # One transaction: password change (which also clears the reset
        # token fields), then the atomic version bump. The disconnect
        # broadcast waits for the commit.
        case update_and_bump_version(User.password_changeset(user, %{password: password})) do
          {:ok, user} ->
            broadcast_disconnect(user)
            {:ok, user}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def reset_user_password(_token, _password),
    do: {:error, :invalid_or_expired_password_reset_token}

  @doc """
  Fetches a map of users by their IDs.

  Returns a map where keys are user IDs and values are user structs.
  Only returns users that exist. Each user carries the seat badges: `level`
  (all-time, from XP) and `pin` (`"classic"` or nil), looked up for all users
  in one more query.

  ## Examples

      iex> PidroServer.Accounts.Auth.get_users_map(["1", "999"])
      %{"1" => %User{id: 1, ...}}
  """
  def get_users_map(user_ids) do
    # Filter out non-UUID IDs (like bot IDs or "dev_host")
    valid_uuids = Enum.filter(user_ids, &valid_uuid?/1)

    if valid_uuids == [] do
      %{}
    else
      from(u in User,
        left_join: a in PidroServer.Accounts.UserAvatar,
        on: a.user_id == u.id,
        where: u.id in ^valid_uuids,
        select_merge: %{
          avatar_url:
            fragment(
              "CASE WHEN ? IS NULL THEN NULL ELSE ?::text || '/api/v1/users/' || ?::text || '/avatar/' || ? END",
              a.version,
              ^PidroServerWeb.Endpoint.url(),
              u.id,
              a.version
            )
        }
      )
      |> Repo.all()
      |> with_badges()
      |> Map.new(&{&1.id, &1})
    end
  end

  defp with_badges(users) do
    summaries = users |> Enum.map(& &1.id) |> Profiles.summaries_for()

    Enum.map(users, fn user ->
      case Map.get(summaries, user.id) do
        %{veteran_level: level, pin: pin} -> %{user | level: level, pin: pin}
        nil -> %{user | level: Progression.level_for_xp(0), pin: nil}
      end
    end)
  end

  @doc """
  Lists users for admin screens with search, account-type filtering, sorting,
  and pagination.
  """
  def list_users(opts \\ []) do
    page = opts |> Keyword.get(:page, 1) |> normalize_positive_integer(1)

    per_page =
      opts
      |> Keyword.get(:per_page, @default_user_page_size)
      |> normalize_positive_integer(@default_user_page_size)

    query =
      User
      |> search_users(Keyword.get(opts, :search, ""))
      |> filter_guest(Keyword.get(opts, :guest, :all))

    total = Repo.aggregate(query, :count, :id)

    total_pages = max(ceil_div(total, per_page), 1)
    page = min(page, total_pages)

    entries =
      query
      |> sort_users(Keyword.get(opts, :sort, :recent))
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      entries: entries,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  @doc """
  Returns high-level account counts for the admin user management dashboard.
  """
  def user_admin_summary do
    total = Repo.aggregate(User, :count, :id)
    guests = Repo.aggregate(from(u in User, where: u.guest == true), :count, :id)
    registered = total - guests
    with_email = Repo.aggregate(from(u in User, where: not is_nil(u.email)), :count, :id)

    %{
      total: total,
      guests: guests,
      registered: registered,
      with_email: with_email
    }
  end

  @doc """
  Builds a changeset for admin profile edits.

  Uses `User.admin_changeset/2`, the only public-facing path that may toggle
  `guest`. It is reachable from the dev admin panel only.
  """
  def change_user(%User{} = user, attrs \\ %{}) do
    user
    |> User.admin_changeset(admin_user_attrs(attrs))
    |> Accounts.validate_public_name_changes([:username])
  end

  @doc """
  Updates user profile fields managed from the admin panel.

  Uses `User.admin_changeset/2` so the admin panel can toggle `guest`.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.admin_changeset(admin_user_attrs(attrs))
    |> Accounts.validate_public_name_changes([:username])
    |> ClassicNameReservations.validate_changes(user.classic_user_id)
    |> Repo.update()
  end

  @doc """
  Deletes a user account with the single deletion recipe (R15, KTD8).

  One database transaction revokes and strips labels from hosted invites and
  deletes the user's `player_profiles`, `player_achievements`,
  `invite_redemptions`, `invite_events`, incoming and outgoing `friendships` and `blocks`,
  and `users` rows. Only after commit
  does the user leave their in-memory room, each affected room's
  `invite_live_until` get recomputed, and the disconnect broadcast fire.
  Post-commit cleanup is best-effort and logged. `game_stats` and
  `abandonment_events` keep the bare player id (KD9).

  ## Returns

    - `{:ok, user}` - The deleted row
    - `{:error, reason}` - Persistent deletion failed; no persistent mutation
      in the transaction was written
  """
  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, term()}
  def delete_user(%User{} = user) do
    case delete_personal_rows(user) do
      {:ok, {deleted, hosted_rooms}} ->
        after_delete(deleted, hosted_rooms)
        {:ok, deleted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a user only if the persisted row is still a guest.

  The row is locked and reloaded in the same transaction as the deletion, so
  a concurrent guest upgrade either completes first and is preserved, or
  waits until the guest deletion has committed. Persistent deletion uses the
  same recipe and post-commit cleanup as `delete_user/1`.
  """
  @spec delete_guest(Ecto.UUID.t()) ::
          {:ok, User.t()} | {:error, :not_found | :not_a_guest | :claimed_guest | term()}
  def delete_guest(id) when is_binary(id) do
    result =
      Repo.transaction(fn ->
        query = from u in User, where: u.id == ^id, lock: "FOR UPDATE"

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %User{guest: false} ->
            Repo.rollback(:not_a_guest)

          %User{classic_user_id: classic_user_id} when not is_nil(classic_user_id) ->
            Repo.rollback(:claimed_guest)

          %User{guest: true} = guest ->
            delete_personal_rows_in_transaction(guest)
        end
      end)

    case result do
      {:ok, {deleted, hosted_rooms}} ->
        after_delete(deleted, hosted_rooms)
        {:ok, deleted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_delete(%User{id: id} = user, hosted_rooms) do
    safely_after_delete(id, "vacate room seat", fn -> vacate_seat(id) end)

    Enum.each(hosted_rooms, fn room ->
      safely_after_delete(id, "recompute invite window", fn ->
        recompute_invite_live_until(room)
      end)
    end)

    safely_after_delete(id, "broadcast disconnect", fn -> broadcast_disconnect(user) end)
  end

  defp safely_after_delete(user_id, action, fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "Post-delete #{action} failed for user #{user_id}: #{Exception.message(exception)}"
      )
  catch
    kind, reason ->
      Logger.error("Post-delete #{action} failed for user #{user_id}: #{inspect({kind, reason})}")
  end

  defp vacate_seat(user_id) do
    case RoomManager.leave_room(user_id) do
      :ok -> :ok
      {:error, :not_in_room} -> :ok
    end
  end

  # The rooms whose active invites the user hosts, read before those invites
  # are revoked so each live room's invite window can be recomputed after.
  defp hosted_invite_rooms(user_id) do
    now = DateTime.utc_now()

    Repo.all(
      from i in Invite,
        where: i.host_user_id == ^user_id and is_nil(i.revoked_at) and i.expires_at > ^now,
        distinct: true,
        select: {i.room_id, i.room_code}
    )
  end

  defp recompute_invite_live_until({room_id, room_code}) do
    case RoomManager.get_room(room_code) do
      {:ok, %Room{id: ^room_id}} ->
        live_until =
          case Invites.active_for_room(room_id) do
            %Invite{expires_at: expires_at} -> expires_at
            nil -> nil
          end

        RoomManager.note_invite(room_code, live_until)

      _closed_or_recycled_code ->
        :ok
    end
  end

  defp delete_personal_rows(%User{} = user) do
    Repo.transaction(fn -> delete_personal_rows_in_transaction(user) end)
  end

  defp delete_personal_rows_in_transaction(%User{id: id} = user) do
    # Social writers take the same user lock before inserting their edges.
    case Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE") do
      nil -> Repo.rollback(:not_found)
      %User{} -> :ok
    end

    hosted_rooms = hosted_invite_rooms(id)

    case Invites.revoke_hosted(id) do
      {:ok, _revoked} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    Repo.delete_all(from p in PlayerProfile, where: p.user_id == ^id)
    Repo.delete_all(from a in Achievement, where: a.user_id == ^id)
    Repo.delete_all(from x in GameXp, where: x.user_id == ^id)
    Repo.delete_all(from r in Redemption, where: r.user_id == ^id)
    Repo.delete_all(from e in Event, where: e.user_id == ^id)

    Repo.delete_all(
      from f in PidroServer.Friends.Friendship, where: f.user_id == ^id or f.friend_id == ^id
    )

    Repo.delete_all(
      from b in PidroServer.Blocks.Block, where: b.user_id == ^id or b.blocked_id == ^id
    )

    Repo.delete_all(
      from i in PidroServer.Friends.Ignore, where: i.user_id == ^id or i.ignored_id == ^id
    )

    case Repo.delete(user) do
      {:ok, deleted} -> {deleted, hosted_rooms}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp guest_attrs(attrs) do
    %{}
    |> maybe_put_attr(:display_name, fetch_attr(attrs, :display_name))
    |> maybe_put_attr(:install_id, fetch_attr(attrs, :install_id))
    |> maybe_put_attr(
      :guest_creation_token_hash,
      fetch_attr(attrs, :guest_creation_token_hash)
    )
  end

  defp ensure_guest_display_name(%{display_name: _name} = attrs), do: {:ok, attrs}

  defp ensure_guest_display_name(attrs) do
    with {:ok, name} <- GuestNames.generate(), do: {:ok, Map.put(attrs, :display_name, name)}
  end

  defp creation_token_hash(attrs) do
    case fetch_attr(attrs, :creation_token) do
      token when is_binary(token) -> :crypto.hash(:sha256, token)
      _missing -> nil
    end
  end

  defp guest_by_creation_token(token_hash) do
    Repo.one(
      from u in User,
        where:
          u.guest_creation_token_hash == ^token_hash and u.guest == true and
            is_nil(u.classic_user_id),
        limit: 1
    )
  end

  defp recover_guest_retry(changeset, token_hash) do
    if unique_error?(changeset, :guest_creation_token_hash) do
      case guest_by_creation_token(token_hash) do
        %User{} = user -> {:ok, user, :existing}
        nil -> {:error, :creation_conflict}
      end
    else
      {:error, changeset}
    end
  end

  defp insert_guest(attrs, taken_name_keys, generator, attempts_left) do
    username = @guest_username_prefix <> generator.()

    changeset =
      %User{}
      |> User.guest_changeset(Map.put(attrs, :username, username))
      |> Changeset.validate_required(:display_name)
      |> Accounts.validate_public_name_changes([:display_name])
      |> reject_taken_name(taken_name_keys)
      |> ClassicNameReservations.validate_changes()

    case Repo.insert(changeset) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        if attempts_left > 1 and unique_error?(changeset, :username) do
          insert_guest(attrs, taken_name_keys, generator, attempts_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  defp reject_taken_name(changeset, []), do: changeset

  defp reject_taken_name(changeset, taken_name_keys) do
    name = Changeset.get_change(changeset, :display_name)

    if is_binary(name) and User.name_key(name) in taken_name_keys do
      Changeset.add_error(changeset, :display_name, "is already used at this table")
    else
      changeset
    end
  end

  defp upgrade_attrs(attrs) do
    %{}
    |> maybe_put_attr(:email, fetch_attr(attrs, :email))
    |> maybe_put_attr(:password, fetch_attr(attrs, :password))
    |> maybe_put_attr(:username, fetch_attr(attrs, :username))
  end

  defp ensure_email_free(email, user_id) when is_binary(email) do
    lowered = String.downcase(email)

    taken? =
      Repo.exists?(
        from u in User,
          where: fragment("lower(?)", u.email) == ^lowered and u.id != ^user_id
      )

    if taken?, do: {:error, :email_taken}, else: :ok
  end

  defp ensure_email_free(_email, _user_id), do: :ok

  defp ensure_username_free(username, user_id) when is_binary(username) do
    taken? = Repo.exists?(from u in User, where: u.username == ^username and u.id != ^user_id)

    if taken?, do: {:error, :username_taken}, else: :ok
  end

  defp ensure_username_free(_username, _user_id), do: :ok

  defp map_upgrade_result({:ok, user}), do: {:ok, user}

  defp map_upgrade_result({:error, %Changeset{} = changeset}) do
    cond do
      unique_error?(changeset, :email) -> {:error, :email_taken}
      unique_error?(changeset, :username) -> {:error, :username_taken}
      true -> {:error, changeset}
    end
  end

  defp map_upgrade_result({:error, reason}), do: {:error, reason}

  defp unique_error?(%Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  defp get_user_for_login(identifier) do
    if String.contains?(identifier, "@") do
      get_user_by_lower_email(identifier)
    else
      get_user_by_username(identifier)
    end
  end

  defp get_user_by_lower_email(email) do
    lowered = String.downcase(email)
    Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^lowered, limit: 1)
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  defp get_user_by_username_or_email(identifier) do
    normalized = String.trim(identifier)
    normalized_email = String.downcase(normalized)

    Repo.one(
      from u in User,
        where:
          u.username == ^normalized or
            fragment("lower(?)", u.email) == ^normalized_email,
        limit: 1
    )
  end

  # One transaction: apply the changeset, then the atomic version bump. The
  # bump's returned row carries every committed change, so a token minted
  # from it is valid. Never broadcasts; the caller decides after the commit.
  defp update_and_bump_version(%Changeset{} = changeset) do
    Repo.transaction(fn ->
      with {:ok, updated} <- Repo.update(changeset),
           {:ok, bumped} <- increment_token_version(Repo, updated.id) do
        bumped
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Runs the atomic increment through the given repo (the transaction repo
  # inside a Multi) and returns the updated row. Never broadcasts: a caller
  # inside a transaction must wait for the commit before disconnecting.
  defp increment_token_version(repo, id) do
    query = from u in User, where: u.id == ^id, select: u

    case repo.update_all(query, inc: [token_version: 1]) do
      {1, [user]} -> {:ok, user}
      {0, _} -> {:error, :not_found}
    end
  end

  defp broadcast_disconnect(%User{id: id}) do
    PidroServerWeb.Endpoint.broadcast(PidroServerWeb.UserSocket.topic(id), "disconnect", %{})
  end

  defp generate_password_reset_token do
    @password_reset_token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash_password_reset_token(token) do
    :crypto.hash(:sha256, token)
  end

  @doc """
  Lists recent users for development purposes.

  ## Parameters

    - `limit` (integer) - Maximum number of users to return (default: 10)

  ## Returns

    - `[user]` - List of user structs

  ## Examples

      iex> PidroServer.Accounts.Auth.list_recent_users(5)
      [%User{}, ...]
  """
  def list_recent_users(limit \\ 10) do
    Repo.all(from u in User, order_by: [desc: u.inserted_at], limit: ^limit)
  end

  defp search_users(query, nil), do: query
  defp search_users(query, ""), do: query

  defp search_users(query, search) when is_binary(search) do
    search = String.trim(search)

    if search == "" do
      query
    else
      term = "%#{search}%"

      from u in query,
        where:
          ilike(u.username, ^term) or ilike(u.email, ^term) or
            fragment("CAST(? AS TEXT) ILIKE ?", u.id, ^term)
    end
  end

  defp filter_guest(query, guest) when guest in [:guest, "guest"] do
    from u in query, where: u.guest == true
  end

  defp filter_guest(query, guest) when guest in [:registered, "registered"] do
    from u in query, where: u.guest == false
  end

  defp filter_guest(query, _guest), do: query

  defp sort_users(query, sort) when sort in [:username, "username"] do
    from u in query, order_by: [asc: fragment("lower(?)", u.username), desc: u.inserted_at]
  end

  defp sort_users(query, sort) when sort in [:oldest, "oldest"] do
    from u in query, order_by: [asc: u.inserted_at]
  end

  defp sort_users(query, sort) when sort in [:updated, "updated"] do
    from u in query, order_by: [desc: u.updated_at]
  end

  defp sort_users(query, _sort) do
    from u in query, order_by: [desc: u.inserted_at]
  end

  defp admin_user_attrs(attrs) when is_map(attrs) do
    %{}
    |> maybe_put_attr(:username, fetch_attr(attrs, :username))
    |> maybe_put_attr(:email, fetch_attr(attrs, :email))
    |> maybe_put_attr(:guest, fetch_attr(attrs, :guest))
  end

  defp admin_user_attrs(_attrs), do: %{}

  # Reads `key` from an atom- or string-keyed params map, the string key
  # winning as in the admin panel's form params.
  defp fetch_attr(attrs, key), do: Map.get(attrs, Atom.to_string(key), Map.get(attrs, key))

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} when integer > 0 -> integer
      _ -> fallback
    end
  end

  defp normalize_positive_integer(_value, fallback), do: fallback

  defp ceil_div(0, _denominator), do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  # A new username passes the word list (PID-84). A Classic player's own
  # name and existing users are not checked again.
  defp moderate_username(changeset, classic_user_id \\ nil) do
    with {:ok, name} <- Changeset.fetch_change(changeset, :username),
         nil <- changeset.errors[:username],
         false <- ClassicNameReservations.reserved_for?(name, classic_user_id),
         false <- Moderation.allowed?(name) do
      Changeset.add_error(changeset, :username, "is not allowed as a public name")
    else
      _ -> changeset
    end
  end
end

defmodule PidroServer.Accounts.User do
  @moduledoc """
  User schema for the Pidro Server.

  Represents a user account in the system, including both regular and guest users.
  Handles user registration, authentication, and account management.

  ## Changesets

  Each changeset owns a purpose, and the `guest` flag is never cast from
  public params:

    * `registration_changeset/2` and `changeset/2` serve the public API. They
      cast `username`, `email`, `password` and `display_name` only.
    * `guest_changeset/2` builds a guest row from `username`, `display_name`,
      `install_id` and an optional creation-token hash, and forces `guest: true`.
      It is internal to the server.
    * `upgrade_changeset/2` turns a guest into a registered account: it casts
      `email`, `password` and an optional `username` and forces `guest: false`.
    * `admin_changeset/2` is `changeset/2` plus `guest`, for the dev admin
      panel and test fixtures.

  ## Display names

  One rule for every account (KD11, R11), applied by each changeset that
  casts `display_name`: the value is NFKC-normalized, trimmed and has separator
  whitespace collapsed, must not contain control or format characters (Unicode
  `Cc` and `Cf`, which covers the zero-width joiner and bidi overrides), and is
  2 to 20 graphemes long.
  `name_key/1` derives the look-alike key guest creation compares against.

  ## Share slugs

  `share_slug` is the lowercase ASCII handle in `pidro.online/play/<slug>`.
  Every changeset that gives a registered account its username sets it once,
  at insert or upgrade time, through `share_slug/2`; it never changes
  afterwards, so printed links keep working. Guests have none.

  `token_version` defaults to 0 both in the schema and in the database so a
  freshly inserted struct signs a valid token without a reload.
  `last_seen_at` is written only by `PidroServer.Accounts.Auth.touch_last_seen/1`;
  `install_id` and `guest_creation_token_hash` are stored at guest creation.
  None is logged or exposed by the API.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PidroServer.Mailer

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @display_name_min_graphemes 2
  @display_name_max_graphemes 20
  @install_id_max_length 64
  @username_min_length 3
  @username_max_length 20
  @password_min_length 8
  @share_slug_min_length 3
  @share_slug_max_length 30
  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @bio_edge_whitespace ~r/^[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}-\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}-\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+$/u

  # Unicode categories Cc (control) and Cf (format). The `u` modifier makes
  # the property classes match codepoints rather than bytes.
  @forbidden_name_chars ~r/[\p{Cc}\p{Cf}]/u
  @name_separators ~r/[\p{Zs}]+/u
  @combining_marks ~r/\p{Mn}/u
  @non_alphanumerics ~r/[^\p{L}\p{N}]/u

  @typedoc "A user row."
  @type t :: %__MODULE__{}

  schema "users" do
    field(:username, :string)
    field(:email, :string)
    field(:display_name, :string)
    field(:share_slug, :string)
    field(:bio, :string)
    field(:password, :string, virtual: true)
    field(:password_hash, :string)
    field(:password_reset_token_hash, :binary)
    field(:password_reset_sent_at, :utc_datetime_usec)
    field(:guest, :boolean, default: false)
    field(:token_version, :integer, default: 0)
    field(:last_seen_at, :utc_datetime_usec)
    field(:install_id, :string)
    field(:guest_creation_token_hash, :binary)
    field(:classic_user_id, :integer)
    field(:classic_claimed_at, :utc_datetime_usec)
    field(:classic_claim_method, Ecto.Enum, values: [:password, :apple, :facebook])

    field(:classic_matched_on, Ecto.Enum,
      values: [:password, :email, :facebook_id, :facebook_business_id]
    )

    field(:apple_sub, :string)
    field(:facebook_id, :string)
    field(:age_band, :string, default: "unknown")
    field(:age_declared_at, :utc_datetime_usec)
    field(:terms_version, :string)
    field(:terms_accepted_at, :utc_datetime_usec)
    field(:avatar_url, :string, virtual: true)
    field(:linked_friend, :map, virtual: true)
    field(:level, :integer, virtual: true)
    field(:pin, :string, virtual: true)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for user registration.

  This changeset is used when creating new user accounts. It validates and
  prepares user data for storage, including password hashing.

  ## Parameters
    - user: The user struct (typically a new/empty one)
    - attrs: The attributes map containing user data

  ## Returns
    A changeset with validation results and prepared data
  """
  def registration_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> validate_required(:password)
    |> validate_length(:password, min: @password_min_length)
    |> put_password_hash()
  end

  @doc false
  def classic_password_registration_changeset(user, attrs) do
    user
    |> registration_changeset(attrs)
    |> validate_required(:email)
  end

  @doc "Builds a passwordless registered account for a verified social claim."
  def social_registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name])
    |> validate_required(:username)
    |> validate_username()
    |> validate_display_name()
    |> unique_constraint(:username)
    |> put_share_slug()
  end

  @doc "Builds an account for a verified provider identity."
  # Keep the legacy provider columns dual-written for rollback safety. They
  # go away in a later release once all readers use user_identities.
  def provider_registration_changeset(user, attrs, :apple, provider_id) do
    user
    |> social_registration_changeset(attrs)
    |> put_change(:apple_sub, provider_id)
    |> unique_constraint(:apple_sub)
  end

  def provider_registration_changeset(user, attrs, :facebook, provider_id) do
    user
    |> social_registration_changeset(attrs)
    |> put_change(:facebook_id, provider_id)
    |> unique_constraint(:facebook_id)
  end

  @doc false
  def classic_claim_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :classic_user_id,
      :classic_claimed_at,
      :classic_claim_method,
      :classic_matched_on,
      :apple_sub,
      :facebook_id,
      :display_name
    ])
    |> validate_required([:classic_user_id, :classic_claimed_at])
    |> validate_display_name()
    |> unique_constraint(:classic_user_id)
    |> unique_constraint(:apple_sub)
    |> unique_constraint(:facebook_id)
    |> check_constraint(:classic_user_id, name: :classic_link_is_complete)
  end

  @doc """
  Builds a changeset for user updates.

  Handles casting and validation of user fields. This changeset can be used for
  both registration and profile updates, but does not require a password.

  The `guest` flag is deliberately not cast here: public params must never be
  able to flag an account as a guest. Use `guest_changeset/2` or
  `admin_changeset/2` for that.

  ## Parameters
    - user: The user struct to update
    - attrs: The attributes map containing updated data

  ## Returns
    A changeset with validation results and prepared data
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password, :display_name])
    |> validate_required([:username])
    |> validate_username()
    |> validate_email()
    |> validate_display_name()
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> unique_constraint(:email, name: :users_lower_email_index)
    |> put_share_slug()
  end

  @doc "Builds a changeset that can change only the public profile biography."
  def bio_changeset(user, attrs) when is_map(attrs) do
    case fetch_attr(attrs, :bio) do
      :error ->
        change(user)

      {:ok, nil} ->
        change(user, bio: nil)

      {:ok, bio} when is_binary(bio) ->
        normalize_bio(user, bio)

      {:ok, _invalid} ->
        user
        |> change()
        |> add_error(:bio, "must be a string or null")
    end
  end

  defp normalize_bio(user, bio) do
    if String.valid?(bio) and not String.contains?(bio, <<0>>) do
      normalized =
        bio
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> then(&Regex.replace(@bio_edge_whitespace, &1, ""))

      user
      |> change(bio: if(normalized == "", do: nil, else: normalized))
      |> validate_length(:bio, max: 280, count: :codepoints)
    else
      user
      |> change()
      |> add_error(:bio, "contains invalid Unicode")
    end
  end

  defp fetch_attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.get(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.get(attrs, Atom.to_string(key))}
      true -> :error
    end
  end

  @doc """
  Builds a changeset for creating a guest account.

  Guests are created by the server, never from public params: this changeset
  casts only `username`, `display_name`, `install_id` (at most 64 characters)
  and `guest_creation_token_hash`, forces `guest: true`, and leaves `email`
  and `password_hash` nil. Username is required, at least 3 characters and
  unique.

  ## Parameters
    - user: The user struct (typically a new/empty one)
    - attrs: The attributes map with `username`, optional `display_name`,
      `install_id` and `guest_creation_token_hash`

  ## Returns
    A changeset with validation results and `guest` set to true
  """
  def guest_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :install_id, :guest_creation_token_hash])
    |> validate_required([:username])
    |> validate_length(:username, min: @username_min_length)
    |> validate_length(:install_id, max: @install_id_max_length)
    |> validate_display_name()
    |> unique_constraint(:username)
    |> unique_constraint(:guest_creation_token_hash)
    |> put_change(:guest, true)
  end

  @doc """
  Builds the changeset that upgrades a guest into a registered account (R13).

  Casts `email`, `password` and an optional `username`; requires email and
  password; applies the email format of `changeset/2`, the password minimum
  of `registration_changeset/2` and the username minimum when a username is
  given; hashes the password and forces `guest: false`. The row keeps its id,
  display name and, unless a username is given, its generated guest username.

  ## Parameters
    - user: The guest's user struct
    - attrs: The attributes map with `email`, `password` and optional `username`

  ## Returns
    A changeset with validation results, the password hash and `guest` false
  """
  def upgrade_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :username])
    |> validate_required([:username, :email, :password])
    |> validate_username()
    |> validate_email()
    |> validate_length(:password, min: @password_min_length)
    |> put_password_hash()
    |> put_change(:guest, false)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> unique_constraint(:email, name: :users_lower_email_index)
    |> put_share_slug()
  end

  @doc """
  Saves a guest who proved a Classic claim with Apple or Facebook: that
  identity is now the way back in, so the row becomes a registered account
  with a share slug. The id, names and progress stay.
  """
  def social_save_changeset(user) do
    user
    |> change(guest: false)
    |> put_share_slug()
  end

  @doc """
  Builds a changeset for admin edits, which may also toggle `guest`.

  This is `changeset/2` plus the `guest` flag. It is used by the dev admin
  panel and by test fixtures, and must not be reachable from public params.

  ## Parameters
    - user: The user struct to update
    - attrs: The attributes map containing updated data, optionally `guest`

  ## Returns
    A changeset with validation results and prepared data
  """
  def admin_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:guest])
  end

  @doc """
  Builds a changeset for updating a user's password.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required(:password)
    |> validate_length(:password, min: @password_min_length)
    |> put_password_hash()
    |> put_change(:password_reset_token_hash, nil)
    |> put_change(:password_reset_sent_at, nil)
  end

  @doc """
  Stores password-reset token metadata.
  """
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password_reset_token_hash, :password_reset_sent_at])
  end

  @doc "The name other players see: the display name, or the username until one is set."
  @spec public_name(%__MODULE__{}) :: String.t() | nil
  def public_name(%__MODULE__{display_name: display_name, username: username}) do
    display_name || username
  end

  @doc """
  Derives the look-alike key of a display name (R11).

  NFKD-decomposes the name, strips combining marks, downcases it and keeps
  only letters and digits, so `Marcél`, `MARCEL` and `m a r c e l` share the
  key `marcel`. When nothing alphanumeric remains (an emoji-only name), the
  key is the NFKC-normalized, trimmed, downcased name itself, so two different
  emoji names stay distinct. `nil` keys to `nil`.

  ## Examples

      iex> PidroServer.Accounts.User.name_key("Marcél")
      "marcel"

      iex> PidroServer.Accounts.User.name_key("m a r c e l")
      "marcel"
  """
  @spec name_key(String.t() | nil) :: String.t() | nil
  def name_key(nil), do: nil

  def name_key(name) when is_binary(name) do
    key =
      name
      |> nfkd()
      |> String.replace(@combining_marks, "")
      |> String.downcase()
      |> String.replace(@non_alphanumerics, "")

    if key == "" do
      name |> nfkc() |> String.trim() |> String.downcase()
    else
      key
    end
  end

  @doc """
  Derives the share slug of a username: the first of `base`, `base-2`,
  `base-3`, ... for which `taken?` answers false.

  The base is the username NFKD-decomposed with combining marks dropped (so
  `å`, `ä`, `ö` and `ü` become `a`, `a`, `o` and `u`), downcased, whitespace
  turned into `-`, everything outside `[a-z0-9-]` stripped and dashes
  collapsed and trimmed. A base shorter than 3 characters is prefixed with
  `player-`. Every candidate is at most 30 characters.

  ## Examples

      iex> PidroServer.Accounts.User.share_slug("Björn Ågren", fn _ -> false end)
      "bjorn-agren"

      iex> PidroServer.Accounts.User.share_slug("bengt", &(&1 == "bengt"))
      "bengt-2"
  """
  @spec share_slug(String.t(), (String.t() -> boolean())) :: String.t()
  def share_slug(username, taken?) when is_binary(username) do
    base = share_slug_base(username)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&share_slug_candidate(base, &1))
    |> Enum.find(&(not taken?.(&1)))
  end

  defp share_slug_base(username) do
    slug =
      username
      |> nfkd()
      |> String.replace(@combining_marks, "")
      |> String.downcase()
      |> String.replace(~r/\s+/u, "-")
      |> String.replace(~r/[^a-z0-9-]/, "")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    if String.length(slug) < @share_slug_min_length,
      do: String.trim_trailing("player-" <> slug, "-"),
      else: slug
  end

  defp share_slug_candidate(base, 1), do: fit_slug(base, @share_slug_max_length)

  defp share_slug_candidate(base, n) do
    suffix = "-#{n}"
    fit_slug(base, @share_slug_max_length - byte_size(suffix)) <> suffix
  end

  defp fit_slug(base, length), do: base |> String.slice(0, length) |> String.trim_trailing("-")

  # Runs at insert/update time, after the changeset is valid, so the final
  # `guest` flag and username decide. An existing slug is never replaced.
  defp put_share_slug(changeset) do
    changeset
    |> unique_constraint(:share_slug)
    |> prepare_changes(fn changeset ->
      if get_field(changeset, :guest) or get_field(changeset, :share_slug) do
        changeset
      else
        slug =
          share_slug(get_field(changeset, :username), fn slug ->
            changeset.repo.exists?(from(u in __MODULE__, where: u.share_slug == ^slug))
          end)

        put_change(changeset, :share_slug, slug)
      end
    end)
  end

  @doc false
  def public_name_changeset(name) do
    %__MODULE__{}
    |> cast(%{display_name: name}, [:display_name])
    |> validate_display_name()
  end

  @doc """
  The one rule for an email address, on any changeset with an `email` field:
  a plain `name@domain.tld` shape that our mailer can also send to.
  """
  def validate_email(changeset) do
    validate_change(changeset, :email, fn :email, email ->
      if email =~ @email_format and Mailer.sendable?(email),
        do: [],
        else: [email: {"must be a valid email address", validation: :format}]
    end)
  end

  # The one display-name rule (KTD6): NFKC normalize, trim and collapse Unicode
  # separator spaces, reject control and format characters, then bound the
  # grapheme count. Applied by every changeset that casts display_name. A blank
  # name normalizes to nil, which clears the field.
  defp validate_display_name(changeset) do
    changeset
    |> update_change(:display_name, &normalize_display_name/1)
    |> validate_change(:display_name, &forbid_control_and_format/2)
    |> validate_length(:display_name,
      min: @display_name_min_graphemes,
      max: @display_name_max_graphemes
    )
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: @username_min_length, max: @username_max_length)
    |> validate_change(:username, &forbid_control_and_format/2)
  end

  defp normalize_display_name(nil), do: nil

  defp normalize_display_name(name) when is_binary(name) do
    case name |> nfkc() |> String.trim() |> String.replace(@name_separators, " ") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp forbid_control_and_format(field, name) do
    if String.valid?(name) and not Regex.match?(@forbidden_name_chars, name) do
      []
    else
      [{field, "must not contain control or format characters"}]
    end
  end

  # :unicode answers an error tuple for invalid UTF-8; the name then flows
  # unchanged into forbid_control_and_format/2, which rejects it.
  defp nfkc(name) do
    case :unicode.characters_to_nfkc_binary(name) do
      normalized when is_binary(normalized) -> normalized
      _invalid -> name
    end
  end

  defp nfkd(name) do
    case :unicode.characters_to_nfkd_binary(name) do
      normalized when is_binary(normalized) -> normalized
      _invalid -> name
    end
  end

  @doc false
  defp put_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp put_password_hash(changeset) do
    changeset
  end
end

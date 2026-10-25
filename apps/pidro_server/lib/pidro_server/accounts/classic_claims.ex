defmodule PidroServer.Accounts.ClassicClaims do
  @moduledoc """
  Redeems verified Classic claims without merging or replacing accounts.

  PID-143 issues an opaque, short-lived ticket after verification. This module
  owns the durable one-to-one link, career import and repeat-sign-in identity.

  Optional `friend_ids`, `friended_by_ids` and `blocked_ids` arrays in the
  ticket's `legacy_data` become Classic social facts after progression import.
  Older tickets without these arrays remain valid.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias PidroServer.Accounts

  alias PidroServer.Accounts.{
    Auth,
    ClassicClaimTicket,
    ClassicNameReservations,
    User,
    UserIdentities
  }

  alias PidroServer.ClassicSocial
  alias PidroServer.Invites
  alias PidroServer.Profiles
  alias PidroServer.Profiles.{LegacyProgression, PlayerProfile}
  alias PidroServer.Repo

  @ticket_bytes 32

  @doc """
  Stores a verified claim and returns its one-time opaque token.

  The caller is PID-143's verifier. `attrs` must contain trusted Classic data,
  a method, and exactly one binding: `user_id` or `install_id`.
  """
  def issue_ticket(attrs) when is_map(attrs) do
    token = @ticket_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = DateTime.utc_now()
    classic_user_id = fetch(attrs, :classic_user_id)
    method = fetch(attrs, :method)
    identity = fetch(attrs, :provider_identity) || %{}

    legacy_data =
      attrs
      |> fetch(:legacy_data)
      |> LegacyProgression.new()
      |> Map.from_struct()
      |> Map.merge(ClassicSocial.legacy_data(fetch(attrs, :legacy_data)))
      |> Map.put(:classic_user_id, classic_user_id)
      |> put_new_account(fetch(attrs, :new_account))

    ticket_attrs = %{
      token_hash: hash_token(token),
      classic_user_id: classic_user_id,
      method: method,
      matched_on: fetch(attrs, :matched_on) || default_matched_on(method),
      provider_id: fetch(attrs, :provider_id),
      provider_issuer_app: fetch(identity, :issuer_app),
      provider_email: fetch(identity, :email),
      provider_email_is_relay: fetch(identity, :email_is_relay) || false,
      provider_business_ids: fetch(identity, :business_ids),
      legacy_data: legacy_data,
      bound_user_id: fetch(attrs, :user_id),
      install_id: fetch(attrs, :install_id),
      expires_at: DateTime.add(now, ticket_ttl_seconds(), :second)
    }

    case %ClassicClaimTicket{}
         |> ClassicClaimTicket.issue_changeset(ticket_attrs)
         |> Repo.insert() do
      {:ok, ticket} -> {:ok, %{ticket: token, expires_at: ticket.expires_at}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The username and email a password claim gives a new account, taken from
  Classic and offered at verify time. Each is nil when the player must choose
  it: Classic has none, it breaks the account rules, or another Pidro account
  has it. The Classic name reserved to `classic_user_id` counts as free.
  """
  def new_account(classic, classic_user_id, user \\ nil) when is_map(classic) do
    changeset =
      %User{}
      |> User.changeset(%{
        username: trim(fetch(classic, :username)),
        email: fetch(classic, :email)
      })
      |> Accounts.validate_public_name_changes([:username])
      |> ClassicNameReservations.validate_changes(classic_user_id)

    others = if user, do: from(u in User, where: u.id != ^user.id), else: User

    %{
      username: offer(changeset, :username, &from(u in others, where: u.username == ^&1)),
      email:
        offer(
          changeset,
          :email,
          &from(u in others, where: fragment("lower(?)", u.email) == ^String.downcase(&1))
        )
    }
  end

  defp offer(changeset, field, holders) do
    with value when is_binary(value) <- Changeset.get_change(changeset, field),
         false <- Keyword.has_key?(changeset.errors, field),
         false <- Repo.exists?(holders.(value)) do
      value
    else
      _choose -> nil
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp put_new_account(legacy_data, nil), do: legacy_data

  defp put_new_account(legacy_data, new_account),
    do: Map.put(legacy_data, :new_account, new_account)

  @doc """
  Says whether a Classic account is linked to someone other than `user_id`.

  Returns nil when it is free or linked to that user, otherwise the way its
  owner signs in, chosen as the claim's 409 chooses it.
  """
  def already_claimed(classic_user_id, method, user_id) do
    case Repo.get_by(User, classic_user_id: classic_user_id) do
      nil -> nil
      %User{id: ^user_id} -> nil
      owner -> %{sign_in_method: sign_in_method(owner, method)}
    end
  end

  @doc "Redeems a ticket for the current user, or creates a user for an install-bound claim."
  def redeem(token, current_user, params)
      when is_binary(token) and (is_nil(current_user) or is_struct(current_user, User)) and
             is_map(params) do
    redeemed =
      case redeem_once(token, current_user, params) do
        {:error, :claim_state_changed} -> redeem_once(token, current_user, params)
        result -> result
      end

    result = resolve_social(redeemed, fetch(params, :friend_slug))
    record_upgrade(redeemed)
    result
  end

  def redeem(_token, _current_user, _params), do: {:error, :invalid_claim_ticket}

  defp redeem_once(token, current_user, params) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case find_ticket(token) do
        nil ->
          Repo.rollback(:invalid_claim_ticket)

        preview ->
          locked_user = lock_known_user(preview, current_user)

          with %ClassicClaimTicket{} = ticket <- lock_ticket(token),
               :ok <- validate_ticket_snapshot(preview, ticket, locked_user),
               :ok <- validate_binding(ticket, current_user, params),
               :ok <- validate_expiry(ticket, now),
               :ok <- precheck_claim_owner(ticket, locked_user),
               {:ok, params} <- validate_account(params),
               params = take_new_account(ticket, params),
               {:ok, display_name} <- claim_display_name(ticket, locked_user, params),
               params = put_account_display_name(params, display_name),
               :ok <- lock_claim_names(current_user, params),
               :ok <- lock_classic(ticket.classic_user_id),
               {:ok, user, mode} <- target_user(ticket, current_user, params, locked_user),
               {:ok, user} <- redeem_for_user(ticket, user, mode, now, display_name, params) do
            {user, is_nil(locked_user) or is_nil(locked_user.classic_user_id),
             is_nil(locked_user) or locked_user.guest,
             not is_nil(locked_user) and locked_user.guest and not user.guest}
          else
            nil -> Repo.rollback(:invalid_claim_ticket)
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  # Resolve only a new link, after commit. Retrying a sign-in must not restore
  # friends removed or blocks unblocked since the original claim.
  defp resolve_social({:ok, {user, new_link?, registered?, _upgraded?}}, friend_slug) do
    if new_link?, do: ClassicSocial.resolve_classic(user)

    if registered?,
      do: PidroServer.Friends.link_signup({:ok, user}, friend_slug),
      else: {:ok, user}
  end

  defp resolve_social(error, _friend_slug), do: error

  # A guest the claim saved counts as upgraded, as through POST /auth/upgrade.
  # Decided on the locked row, so two concurrent redemptions count once.
  # After the commit: a failed event write must not undo the claim.
  defp record_upgrade({:ok, {%User{id: id}, _new_link?, _registered?, true}}),
    do: Invites.record_upgrade(id)

  defp record_upgrade(_result), do: :ok

  defp find_ticket(token),
    do: Repo.get_by(ClassicClaimTicket, token_hash: hash_token(token))

  defp lock_ticket(token) do
    Repo.one(
      from t in ClassicClaimTicket,
        where: t.token_hash == ^hash_token(token),
        lock: "FOR UPDATE"
    )
  end

  defp lock_known_user(_ticket, %User{id: id}), do: lock_user(id)
  defp lock_known_user(%{redeemed_by_id: id}, nil) when is_binary(id), do: lock_user(id)
  defp lock_known_user(_ticket, nil), do: nil

  # A concurrent first redemption can commit while this transaction waits for
  # the ticket. Restart so the established user is locked before the ticket.
  defp validate_ticket_snapshot(
         %{redeemed_by_id: nil},
         %{redeemed_by_id: id},
         nil
       )
       when is_binary(id),
       do: {:error, :claim_state_changed}

  defp validate_ticket_snapshot(_preview, _ticket, _locked_user), do: :ok

  defp validate_binding(%{bound_user_id: id}, %User{id: id}, _params), do: :ok

  defp validate_binding(%{bound_user_id: nil, install_id: install_id}, nil, params) do
    if fetch(params, :install_id) == install_id,
      do: :ok,
      else: {:error, :claim_ticket_binding_mismatch}
  end

  defp validate_binding(_ticket, _user, _params),
    do: {:error, :claim_ticket_binding_mismatch}

  defp validate_expiry(%{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, :claim_ticket_expired}
  end

  defp precheck_claim_owner(%{redeemed_by_id: id}, _user) when is_binary(id), do: :ok

  defp precheck_claim_owner(ticket, locked_user) do
    case already_claimed(ticket.classic_user_id, ticket.method, locked_user && locked_user.id) do
      nil -> :ok
      %{sign_in_method: method} -> {:error, {:already_claimed, method}}
    end
  end

  defp validate_account(params) do
    cond do
      not Map.has_key?(params, :account) and not Map.has_key?(params, "account") ->
        {:ok, params}

      is_nil(fetch(params, :account)) or is_map(fetch(params, :account)) ->
        {:ok, params}

      true ->
        changeset =
          %User{}
          |> Changeset.change()
          |> Changeset.add_error(:account, "must be an object")

        {:error, changeset}
    end
  end

  defp claim_display_name(%{redeemed_by_id: id}, _user, _params) when is_binary(id),
    do: {:ok, nil}

  defp claim_display_name(ticket, %User{classic_user_id: classic_user_id}, _params)
       when classic_user_id == ticket.classic_user_id,
       do: {:ok, nil}

  defp claim_display_name(ticket, _user, params) do
    case account_display_name(params) do
      {:ok, name} ->
        validate_claim_display_name(name)

      :missing ->
        case effective_name_allowed(ticket) do
          true -> validate_claim_display_name(fetch(ticket.legacy_data, :classic_username))
          false -> validate_claim_display_name(nil)
          nil -> {:ok, nil}
        end
    end
  end

  defp account_display_name(params) do
    case fetch(params, :account) do
      account when is_map(account) ->
        cond do
          Map.has_key?(account, "display_name") -> {:ok, account["display_name"]}
          Map.has_key?(account, :display_name) -> {:ok, account[:display_name]}
          true -> :missing
        end

      _missing ->
        :missing
    end
  end

  defp ticket_ttl_seconds do
    :pidro_server
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:ticket_ttl_seconds)
  end

  defp effective_name_allowed(ticket) do
    case fetch(ticket.legacy_data, :classic_name_allowed) do
      allowed when is_boolean(allowed) ->
        allowed

      nil ->
        # Tickets live for ten minutes. Re-evaluate older unredeemed tickets
        # that carry a name; synthetic legacy tickets without one keep their
        # prior behavior.
        case fetch(ticket.legacy_data, :classic_username) do
          name when is_binary(name) -> Accounts.public_name_allowed?(name)
          _legacy_ticket_without_name -> nil
        end
    end
  end

  defp validate_claim_display_name(name) do
    changeset =
      name
      |> User.public_name_changeset()
      |> Changeset.validate_required(:display_name)
      |> Accounts.validate_public_name_changes([:display_name])

    if changeset.valid? do
      {:ok, Changeset.get_field(changeset, :display_name)}
    else
      {:error, changeset}
    end
  end

  # The username and email offered at verify time are Classic's, not the
  # player's: whatever the request sends for them is replaced.
  defp take_new_account(ticket, params) do
    offered = fetch(ticket.legacy_data, :new_account) || %{}

    Enum.reduce([:username, :email], params, fn field, params ->
      case fetch(offered, field) do
        value when is_binary(value) -> put_account(params, field, value)
        _choose -> params
      end
    end)
  end

  defp put_account_display_name(params, nil), do: params

  defp put_account_display_name(params, display_name),
    do: put_account(params, :display_name, display_name)

  defp put_account(params, field, value) do
    account = fetch(params, :account) || %{}

    if Map.has_key?(params, "account") do
      Map.put(params, "account", Map.put(account, Atom.to_string(field), value))
    else
      Map.put(params, :account, Map.put(account, field, value))
    end
  end

  # A guest's password claim may also take a new username (save_guest/3).
  defp lock_claim_names(%User{} = user, params) do
    account = fetch(params, :account) || %{}

    ClassicNameReservations.lock_claim_names([
      user.username,
      fetch(account, :username),
      fetch(account, :display_name) || user.display_name
    ])
  end

  defp lock_claim_names(nil, params),
    do: ClassicNameReservations.lock_claim_names(fetch(params, :account) || %{})

  defp lock_classic(classic_user_id) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
           "classic-claim:#{classic_user_id}"
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_user(%{redeemed_by_id: id}, %User{id: id}, _params, %User{id: id} = user),
    do: {:ok, user, :retry}

  defp target_user(
         %{redeemed_by_id: id, install_id: install_id},
         nil,
         params,
         %User{id: id} = user
       )
       when is_binary(id) do
    if fetch(params, :install_id) == install_id,
      do: {:ok, user, :retry},
      else: {:error, :claim_ticket_binding_mismatch}
  end

  defp target_user(%{redeemed_by_id: id, method: method}, _current_user, _params, owner)
       when is_binary(id),
       do: {:error, {:already_claimed, sign_in_method(owner, method)}}

  defp target_user(_ticket, %User{id: id}, _params, %User{id: id} = user),
    do: {:ok, user, :first}

  defp target_user(ticket, nil, params, nil) do
    case Repo.get_by(User, classic_user_id: ticket.classic_user_id) do
      nil -> create_user(ticket, fetch(params, :account) || %{})
      owner -> {:error, {:already_claimed, sign_in_method(owner, ticket.method)}}
    end
  end

  defp create_user(%{method: :password, classic_user_id: classic_user_id}, attrs) do
    %User{}
    |> User.classic_password_registration_changeset(attrs)
    |> Accounts.validate_public_name_changes([:username, :display_name])
    |> ClassicNameReservations.validate_changes(classic_user_id)
    |> Repo.insert()
    |> with_mode()
  end

  defp create_user(%{method: method, classic_user_id: classic_user_id}, attrs)
       when method in [:apple, :facebook] do
    %User{}
    |> User.social_registration_changeset(attrs)
    |> Accounts.validate_public_name_changes([:username, :display_name])
    |> ClassicNameReservations.validate_changes(classic_user_id)
    |> Repo.insert()
    |> with_mode()
  end

  defp with_mode({:ok, user}), do: {:ok, user, :first}
  defp with_mode({:error, reason}), do: {:error, reason}

  defp redeem_for_user(ticket, user, :retry, _now, _display_name, _params) do
    if user.classic_user_id == ticket.classic_user_id,
      do: {:ok, user},
      else: {:error, :already_claimed}
  end

  defp redeem_for_user(ticket, user, :first, now, display_name, params) do
    already_linked? = user.classic_user_id == ticket.classic_user_id

    with :ok <- ensure_link_available(ticket, user),
         :ok <- ensure_provider_available(ticket, user),
         {:ok, linked} <- link_user(ticket, user, now, display_name),
         {:ok, linked} <- save_guest(ticket, linked, params),
         {:ok, linked} <- link_provider_identity(ticket, linked, now),
         :ok <- maybe_import_progression(already_linked?, linked, ticket),
         {:ok, _ticket} <-
           ticket |> ClassicClaimTicket.redeem_changeset(linked.id, now) |> Repo.update() do
      {:ok, linked}
    end
  end

  # A guest who claims by password must leave with a way back in: the same
  # upgrade as POST /auth/upgrade, in this transaction, after the link so the
  # Classic name is reserved for this claim.
  defp save_guest(%{method: :password}, %User{guest: true} = guest, params) do
    account = fetch(params, :account) || %{}

    with :ok <- require_credentials(account) do
      guest
      |> Auth.upgrade_guest(Map.drop(account, [:friend_slug, "friend_slug"]))
      |> taken_as_changeset()
    end
  end

  # A guest who claims with Apple or Facebook signs in with it from now on, so
  # the account is saved: it may sit with strangers and keep its friends.
  defp save_guest(%{method: method}, %User{guest: true} = guest, _params)
       when method in [:apple, :facebook] do
    guest |> User.social_save_changeset() |> Repo.update()
  end

  defp save_guest(_ticket, user, _params), do: {:ok, user}

  defp require_credentials(account) do
    changeset =
      Enum.reduce(
        [
          email: "Add an email address to claim your Classic account",
          password: "Add a password to claim your Classic account"
        ],
        Changeset.change(%User{}),
        fn {field, message}, changeset ->
          if present?(fetch(account, field)),
            do: changeset,
            else: Changeset.add_error(changeset, field, message)
        end
      )

    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp taken_as_changeset({:error, :email_taken}), do: taken_error(:email)
  defp taken_as_changeset({:error, :username_taken}), do: taken_error(:username)
  defp taken_as_changeset(result), do: result

  defp taken_error(field) do
    {:error, Changeset.add_error(Changeset.change(%User{}), field, "has already been taken")}
  end

  defp ensure_provider_available(%{method: :password}, _user), do: :ok

  defp ensure_provider_available(%{method: :apple, provider_id: id}, %User{apple_sub: current}) do
    if current in [nil, id], do: :ok, else: {:error, :provider_already_linked}
  end

  defp ensure_provider_available(
         %{method: :facebook, provider_id: id},
         %User{facebook_id: current}
       ) do
    if current in [nil, id], do: :ok, else: {:error, :provider_already_linked}
  end

  defp ensure_link_available(ticket, user) do
    if user.classic_user_id in [nil, ticket.classic_user_id] do
      owner =
        Repo.one(
          from u in User,
            where: u.classic_user_id == ^ticket.classic_user_id
        )

      if is_nil(owner) or owner.id == user.id,
        do: :ok,
        else: {:error, {:already_claimed, sign_in_method(owner, ticket.method)}}
    else
      {:error, :user_already_claimed}
    end
  end

  defp sign_in_method(%User{} = user, attempted_method) do
    methods =
      [
        {:password, user.password_hash},
        {:apple, user.apple_sub},
        {:facebook, user.facebook_id}
      ]
      |> Enum.filter(fn {_method, identity} -> is_binary(identity) end)
      |> Enum.map(&elem(&1, 0))

    if attempted_method in methods, do: attempted_method, else: List.first(methods)
  end

  defp sign_in_method(_user, _attempted_method), do: nil

  defp link_user(ticket, user, now, display_name) do
    attrs =
      %{
        classic_user_id: ticket.classic_user_id,
        classic_claimed_at: user.classic_claimed_at || now,
        classic_claim_method: ticket.method,
        classic_matched_on: ticket.matched_on
      }
      |> put_provider(ticket.method, ticket.provider_id)
      |> maybe_put_display_name(display_name)

    changeset =
      user
      |> User.classic_claim_changeset(attrs)
      |> maybe_force_display_name(display_name)
      |> Accounts.validate_public_name_changes([:display_name])
      |> ClassicNameReservations.validate_changes(ticket.classic_user_id)

    changeset
    |> Repo.update()
    |> map_link_error(ticket.method)
  end

  defp maybe_put_display_name(attrs, name) when is_binary(name),
    do: Map.put(attrs, :display_name, name)

  defp maybe_put_display_name(attrs, _name), do: attrs

  defp maybe_force_display_name(changeset, name) when is_binary(name) do
    Changeset.force_change(
      changeset,
      :display_name,
      Changeset.get_field(changeset, :display_name)
    )
  end

  defp maybe_force_display_name(changeset, _name), do: changeset

  # These legacy columns remain dual-written for rollback safety and will be
  # removed in a later release after every consumer uses user_identities.
  defp put_provider(attrs, :apple, provider_id), do: Map.put(attrs, :apple_sub, provider_id)
  defp put_provider(attrs, :facebook, provider_id), do: Map.put(attrs, :facebook_id, provider_id)
  defp put_provider(attrs, :password, _provider_id), do: attrs

  defp link_provider_identity(%{method: :password}, user, _now), do: {:ok, user}

  defp link_provider_identity(ticket, user, now) do
    UserIdentities.link(
      user,
      %{
        provider: ticket.method,
        subject: ticket.provider_id,
        issuer_app: ticket.provider_issuer_app,
        email: ticket.provider_email,
        email_is_relay: ticket.provider_email_is_relay,
        business_ids: ticket.provider_business_ids || []
      },
      :claim,
      now
    )
  end

  defp map_link_error({:ok, user}, _method), do: {:ok, user}

  defp map_link_error({:error, changeset}, method) do
    cond do
      unique_error?(changeset, :classic_user_id) -> {:error, {:already_claimed, method}}
      unique_error?(changeset, :apple_sub) -> {:error, :provider_already_linked}
      unique_error?(changeset, :facebook_id) -> {:error, :provider_already_linked}
      true -> {:error, changeset}
    end
  end

  defp maybe_import_progression(true, _user, _ticket), do: :ok
  defp maybe_import_progression(false, user, ticket), do: import_progression(user, ticket)

  defp import_progression(user, ticket) do
    result =
      case Profiles.import_legacy_progression(user, ticket.legacy_data) do
        {:ok, %PlayerProfile{}} -> :ok
        {:ok, :already_migrated} -> ensure_same_import(user.id, ticket.classic_user_id)
        {:error, reason} -> {:error, reason}
      end

    with :ok <- result do
      ClassicSocial.store(ticket.classic_user_id, ticket.legacy_data)
    end
  end

  defp ensure_same_import(user_id, classic_user_id) do
    profile = Repo.get_by!(PlayerProfile, user_id: user_id)
    imported_id = Map.get(profile.heritage_flags || %{}, "classic_user_id")

    if imported_id == classic_user_id,
      do: :ok,
      else: {:error, :user_already_claimed}
  end

  defp lock_user(id),
    do: Repo.one!(from u in User, where: u.id == ^id, lock: "FOR UPDATE")

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp default_matched_on(:password), do: :password
  defp default_matched_on(:apple), do: :email
  defp default_matched_on(:facebook), do: :facebook_id

  defp fetch(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end

defmodule PidroServer.Accounts.ClassicVerification do
  @moduledoc "Verifies Classic ownership and issues an account-bound claim ticket."

  require Logger

  alias PidroServer.Accounts

  alias PidroServer.Accounts.{
    ClassicClaims,
    ClassicClient,
    FacebookCredential,
    ProviderIdentity,
    User
  }

  alias PidroServer.Profiles.LegacyProgression

  def verify(params, current_user, opts \\ [])

  def verify(params, current_user, opts) when is_map(params) do
    classic = Keyword.get(opts, :classic_client, ClassicClient)
    providers = Keyword.get(opts, :provider_identity, ProviderIdentity)

    with {:ok, binding} <- binding(current_user, params),
         {:ok, method} <- method(params),
         {:ok, profile, identity, matched_on} <- verify_method(method, params, classic, providers),
         {:ok, result} <-
           issue_ticket(binding, method, profile, identity, matched_on, current_user) do
      {:ok, result}
    else
      {:error, :not_found} -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_params, _current_user, _opts), do: {:error, :invalid_credentials}

  @doc """
  Looks up Classic from an already verified provider identity and issues an
  install-bound claim ticket when found.

  Unlike `verify/3`, a missing Classic account remains `:not_found` so provider
  sign-in can safely create a new account. Binding is checked only after a
  match, because a new provider user does not need an install-bound ticket.
  """
  def verify_provider(identity, params, opts \\ [])

  def verify_provider(%{provider: provider} = identity, params, opts)
      when provider in [:apple, :facebook] and is_map(params) do
    classic = Keyword.get(opts, :classic_client, ClassicClient)

    with {:ok, profile, matched_on} <- lookup_provider(classic, identity),
         {:ok, binding} <- binding(nil, params) do
      issue_ticket(binding, provider, profile, identity, matched_on, nil)
    end
  end

  def verify_provider(_identity, _params, _opts),
    do: {:error, :invalid_credentials}

  @doc "The user or install binding shared by Classic ownership proofs."
  def binding(%{id: user_id}, _params), do: {:ok, %{user_id: user_id}}

  def binding(nil, params) do
    case fetch(params, :install_id) do
      install_id
      when is_binary(install_id) and install_id != "" and byte_size(install_id) <= 64 ->
        {:ok, %{install_id: install_id}}

      _invalid ->
        {:error, :claim_binding_required}
    end
  end

  defp method(params) do
    case fetch(params, :method) do
      "password" -> {:ok, :password}
      "apple" -> {:ok, :apple}
      "facebook" -> {:ok, :facebook}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_method(:password, params, classic, _providers) do
    with login when is_binary(login) and login != "" <- fetch(params, :login),
         password when is_binary(password) and password != "" <- fetch(params, :password),
         {:ok, profile} <- classic.verify_password(login, password) do
      {:ok, profile, nil, :password}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_method(:apple, params, classic, providers) do
    with token when is_binary(token) <- fetch(params, :identity_token),
         {:ok, %{"sub" => subject, "email" => email} = claims} <- providers.apple(token),
         true <- claims["email_verified"] in [true, "true"] or {:error, :invalid_credentials},
         true <- (is_binary(email) and email != "") or {:error, :invalid_credentials},
         {:ok, profile} <- logged_apple_lookup(classic, email) do
      identity = %{
        provider: :apple,
        subject: subject,
        issuer_app: apple_audience(claims["aud"]),
        email: email,
        email_is_relay: apple_relay?(claims, email),
        business_ids: []
      }

      {:ok, profile, identity, :email}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_method(:facebook, params, classic, providers) do
    with {:ok, credential} <- FacebookCredential.parse(params) do
      verify_facebook(credential, classic, providers)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_facebook({:access_token, token}, classic, providers) do
    with {:ok, provider_identity} <- providers.facebook(token),
         {:ok, business_ids} <- facebook_business_ids(providers, token) do
      verify_facebook_identity(classic, provider_identity, business_ids)
    end
  end

  defp verify_facebook({:authentication_token, token, nonce}, classic, providers) do
    with {:ok, provider_identity} <- providers.facebook_limited(token, nonce) do
      verify_facebook_identity(classic, provider_identity, [])
    end
  end

  defp verify_facebook_identity(
         classic,
         %{subject: primary_id, issuer_app: issuer_app, email: email},
         business_ids
       ) do
    with true <- (is_binary(primary_id) and primary_id != "") or {:error, :invalid_credentials},
         {:ok, profile, matched_on} <-
           lookup_facebook(classic, primary_id, business_ids, email) do
      identity = %{
        provider: :facebook,
        subject: primary_id,
        issuer_app: issuer_app,
        email: email,
        email_is_relay: false,
        business_ids: business_ids
      }

      {:ok, profile, identity, matched_on}
    end
  end

  defp lookup_provider(classic, %{provider: :apple, email: email}) when is_binary(email) do
    case logged_apple_lookup(classic, email) do
      {:ok, profile} -> {:ok, profile, :email}
      error -> error
    end
  end

  defp lookup_provider(classic, %{
         provider: :facebook,
         subject: primary_id,
         business_ids: business_ids,
         email: email
       }),
       do: lookup_facebook(classic, primary_id, business_ids || [], email)

  defp lookup_provider(_classic, %{provider: provider}) do
    log_provider_match(provider, :no_match)
    {:error, :not_found}
  end

  defp lookup_facebook(classic, primary_id, business_ids, email) do
    case classic.lookup(:fbid, primary_id) do
      {:ok, profile} ->
        if deleted_profile?(profile) do
          lookup_facebook_business(classic, primary_id, business_ids, email)
        else
          log_provider_match(:facebook, :id_match)
          {:ok, profile, :facebook_id}
        end

      {:error, :not_found} ->
        lookup_facebook_business(classic, primary_id, business_ids, email)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_facebook_business(classic, primary_id, business_ids, email) do
    business_ids
    |> Enum.uniq()
    |> Enum.reject(&(&1 == primary_id))
    |> Enum.reduce_while({:error, :not_found}, fn id, _not_found ->
      case classic.lookup(:fbid, id) do
        {:ok, profile} ->
          if deleted_profile?(profile),
            do: {:cont, {:error, :not_found}},
            else: {:halt, {:ok, profile, :facebook_business_id}}

        {:error, :not_found} ->
          {:cont, {:error, :not_found}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _profile, :facebook_business_id} = result ->
        log_provider_match(:facebook, :business_id_match)
        result

      {:error, :not_found} ->
        lookup_facebook_email(classic, email)

      error ->
        error
    end
  end

  defp lookup_facebook_email(classic, email) when is_binary(email) and email != "" do
    case classic.lookup(:email, email) do
      {:ok, profile} ->
        if deleted_profile?(profile) do
          log_provider_match(:facebook, :no_match)
          {:error, :not_found}
        else
          log_provider_match(:facebook, :email_match)
          {:ok, profile, :email}
        end

      {:error, reason} when reason in [:not_found, :ambiguous] ->
        log_provider_match(:facebook, :no_match)
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_facebook_email(_classic, _email) do
    log_provider_match(:facebook, :no_match)
    {:error, :not_found}
  end

  defp logged_apple_lookup(classic, email) do
    case classic.lookup(:email, email) do
      {:ok, profile} ->
        if deleted_profile?(profile) do
          log_provider_match(:apple, :no_match)
          {:error, :not_found}
        else
          log_provider_match(:apple, :email_match)
          {:ok, profile}
        end

      {:error, reason} when reason in [:not_found, :ambiguous] ->
        log_provider_match(:apple, :no_match)
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_provider_match(_provider, outcome) do
    Logger.info("Classic provider match", outcome: outcome)
  end

  defp deleted_profile?(profile),
    do:
      fetch(profile, :account_deleted) == true or get_in(profile, ["account", "deleted"]) == true

  @doc """
  Issues the shared preview and ticket after ownership has been proved.

  Trusted callers only: the caller must verify the proof and its binding before
  passing Classic's profile here. This function does not authenticate a player.
  """
  def issue_ticket(binding, method, profile, identity, matched_on, current_user) do
    provider_id = if identity, do: identity.subject

    with {:ok, classic_user_id} <- classic_user_id(profile),
         legacy = legacy_data(profile),
         {:ok, preview} <- preview(legacy),
         new_account = new_account(method, profile, classic_user_id, current_user),
         {:ok, ticket} <-
           ClassicClaims.issue_ticket(
             binding
             |> Map.merge(%{
               classic_user_id: classic_user_id,
               method: method,
               matched_on: matched_on,
               provider_id: provider_id,
               provider_identity: identity,
               legacy_data: legacy,
               new_account: new_account
             })
           ) do
      {:ok,
       ticket
       |> Map.put(:classic, put_new_account(preview, new_account))
       |> Map.put(
         :already_claimed,
         ClassicClaims.already_claimed(classic_user_id, method, binding[:user_id])
       )}
    end
  end

  # A claim that creates the account it names takes Classic's username: a
  # password claim by a signed-out player or a guest, which also takes Classic's
  # email, and an Apple or Facebook claim by a signed-out player, which needs
  # no email. A guest's social claim keeps the guest's username.
  defp new_account(:password, profile, classic_user_id, nil),
    do: ClassicClaims.new_account(profile, classic_user_id)

  defp new_account(:password, profile, classic_user_id, %User{guest: true} = guest),
    do: ClassicClaims.new_account(profile, classic_user_id, guest)

  defp new_account(method, profile, classic_user_id, nil) when method in [:apple, :facebook],
    do: %{ClassicClaims.new_account(profile, classic_user_id) | email: nil}

  defp new_account(_method, _profile, _classic_user_id, _user), do: nil

  defp put_new_account(preview, nil), do: preview
  defp put_new_account(preview, new_account), do: Map.put(preview, :new_account, new_account)

  defp apple_audience(audience) when is_binary(audience), do: audience
  defp apple_audience([audience | _rest]) when is_binary(audience), do: audience
  defp apple_audience(_audience), do: nil

  defp apple_relay?(claims, email) do
    claims["is_private_email"] in [true, "true"] or
      String.ends_with?(String.downcase(email), "@privaterelay.appleid.com")
  end

  defp facebook_business_ids(providers, token) do
    case providers.facebook_business_ids(token) do
      {:ok, ids} when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
          do: {:ok, ids},
          else: {:error, :provider_unavailable}

      {:ok, []} ->
        {:ok, []}

      {:ok, _malformed} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classic_user_id(profile) do
    case fetch(profile, :id) do
      id when is_integer(id) -> {:ok, id}
      id when is_binary(id) -> parse_integer(id)
      _invalid -> {:error, :provider_unavailable}
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> {:error, :provider_unavailable}
    end
  end

  defp legacy_data(profile) do
    name = classic_name(profile)

    profile
    |> Map.put("classic_username", name)
    |> Map.put("classic_name_allowed", Accounts.public_name_allowed?(name))
    |> Map.put("classic_level", fetch(profile, :level))
    |> Map.put("legacy_played_games", fetch(profile, :played_games))
    |> Map.put("legacy_victories", fetch(profile, :victories))
    |> Map.put("legacy_losses", fetch(profile, :losses))
    |> Map.put("games_played_counter", fetch(profile, :total_game))
    |> Map.put("wins", fetch(profile, :win_game))
    |> Map.put("losses", fetch(profile, :lost_game))
    |> Map.put("games_logged", fetch(profile, :xpoints_count) || fetch(profile, :xpoints))
    |> Map.put("games_started", fetch(profile, :started))
    |> Map.put("games_ended", fetch(profile, :ended))
    |> Map.put("member_since", fetch(profile, :inserted_at))
    |> Map.put("premium", premium?(fetch(profile, :premium_until)))
    |> LegacyProgression.new()
    |> Map.from_struct()
    |> Map.merge(PidroServer.ClassicSocial.legacy_data(profile))
  end

  defp preview(legacy) do
    preview = %{
      name: legacy.classic_username,
      games_played: classic_games_played(legacy),
      level: legacy.classic_level,
      member_since: legacy.member_since,
      name_allowed: legacy.classic_name_allowed
    }

    # Classic recorded no creation date before about 2018, so the oldest
    # accounts arrive with `member_since: nil`; they must still be claimable.
    if (is_nil(preview.name) or is_binary(preview.name)) and
         is_integer(preview.games_played) and preview.games_played >= 0 and
         is_integer(preview.level) and preview.level >= 0 and
         (is_nil(preview.member_since) or
            (is_binary(preview.member_since) and preview.member_since != "")) do
      {:ok, preview}
    else
      {:error, :provider_unavailable}
    end
  end

  defp classic_games_played(legacy) do
    old = legacy.legacy_played_games
    counter = legacy.games_played_counter

    cond do
      is_integer(old) and is_integer(counter) and counter >= old -> counter
      is_integer(old) and is_integer(counter) -> old + counter
      is_integer(counter) -> counter
      is_integer(old) -> old
      true -> nil
    end
  end

  defp classic_name(profile) do
    case fetch(profile, :username) do
      username when is_binary(username) ->
        case String.trim(username) do
          "" -> fetch(profile, :firstname)
          _name -> username
        end

      _blank ->
        fetch(profile, :firstname)
    end
  end

  defp premium?(nil), do: nil

  defp premium?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} -> DateTime.after?(expires_at, DateTime.utc_now())
      _invalid -> nil
    end
  end

  defp premium?(_value), do: nil

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

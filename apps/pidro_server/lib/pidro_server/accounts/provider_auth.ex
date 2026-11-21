defmodule PidroServer.Accounts.ProviderAuth do
  @moduledoc "Apple and Facebook sign-in, Classic discovery, and first-time registration."

  require Logger

  alias PidroServer.Accounts.{
    AppleTokens,
    ClassicNameReservations,
    ClassicVerification,
    FacebookCredential,
    GuestNames,
    ProviderIdentity,
    User,
    UserIdentities
  }

  alias PidroServer.Repo

  @name_attempts 2

  @type provider :: :apple | :facebook
  @type result :: {:ok, User.t()} | {:classic_found, map()}

  @spec authenticate(provider(), String.t() | tuple() | map(), map(), keyword()) ::
          result()
          | {:error,
             :invalid_credentials | :provider_unavailable | :claim_binding_required | term()}
  def authenticate(provider, token, params \\ %{}, opts \\ [])

  def authenticate(:facebook, token, params, opts) when is_binary(token),
    do: authenticate(:facebook, {:access_token, token}, params, opts)

  def authenticate(provider, credential, params, opts)
      when provider in [:apple, :facebook] and is_map(params) do
    providers =
      Keyword.get_lazy(opts, :provider_identity, fn ->
        Application.get_env(:pidro_server, :provider_identity, ProviderIdentity)
      end)

    with {:ok, identity, lookup_context} <- verify(provider, credential, providers) do
      identity = AppleTokens.put_refresh_token(identity, params)

      case UserIdentities.sign_in(identity) do
        {:ok, %User{} = user} ->
          maybe_heal_business_ids(identity, lookup_context, providers)
          {:ok, user}

        {:error, :not_found} ->
          with {:ok, identity} <- complete_identity(identity, lookup_context, providers) do
            find_classic_or_create(identity, params, opts)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def authenticate(_provider, _token, _params, _opts), do: {:error, :invalid_credentials}

  defp verify(:apple, token, providers) when is_binary(token) do
    with {:ok, %{"sub" => provider_id} = claims} <- providers.apple(token),
         true <- valid_id?(provider_id) or {:error, :invalid_credentials} do
      email = verified_apple_email(claims)

      identity = %{
        provider: :apple,
        subject: provider_id,
        issuer_app: apple_audience(claims["aud"]),
        email: email,
        email_is_relay: apple_relay?(claims, email),
        business_ids: []
      }

      {:ok, identity, :complete}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify(:facebook, params, providers) when is_map(params) do
    with {:ok, credential} <- FacebookCredential.parse(params) do
      verify(:facebook, credential, providers)
    end
  end

  defp verify(:facebook, {:access_token, token}, providers) do
    with {:ok, %{subject: provider_id, issuer_app: issuer_app, email: email}} <-
           providers.facebook(token),
         true <- valid_id?(provider_id) or {:error, :invalid_credentials} do
      identity = %{
        provider: :facebook,
        subject: provider_id,
        issuer_app: issuer_app,
        email: email,
        email_is_relay: false,
        business_ids: nil
      }

      {:ok, identity, {:facebook_graph, token}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify(:facebook, {:authentication_token, token, nonce}, providers) do
    with {:ok, %{subject: provider_id, issuer_app: issuer_app, email: email}} <-
           providers.facebook_limited(token, nonce),
         true <- valid_id?(provider_id) or {:error, :invalid_credentials} do
      {:ok,
       %{
         provider: :facebook,
         subject: provider_id,
         issuer_app: issuer_app,
         email: email,
         email_is_relay: false,
         business_ids: []
       }, :complete}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify(_provider, _credential, _providers), do: {:error, :invalid_credentials}

  defp complete_identity(identity, {:facebook_graph, token}, providers) do
    with {:ok, business_ids} <- facebook_business_ids(providers, token) do
      {:ok, %{identity | business_ids: business_ids}}
    end
  end

  defp complete_identity(identity, :complete, _providers), do: {:ok, identity}

  defp maybe_heal_business_ids(
         %{provider: :facebook, subject: subject} = identity,
         {:facebook_graph, token},
         providers
       ) do
    if UserIdentities.business_ids_missing?(:facebook, subject) do
      with {:ok, business_ids} <- facebook_business_ids(providers, token),
           {:ok, _user} <- UserIdentities.sign_in(%{identity | business_ids: business_ids}) do
        :ok
      else
        _failure ->
          Logger.warning("Could not refresh Facebook business IDs for a linked identity")
          :ok
      end
    end
  end

  defp maybe_heal_business_ids(_identity, _lookup_context, _providers), do: :ok

  defp find_classic_or_create(identity, params, opts) do
    verification = Keyword.get(opts, :classic_verification, ClassicVerification)
    classic = Keyword.get(opts, :classic_client, PidroServer.Accounts.ClassicClient)

    case verification.verify_provider(identity, params, classic_client: classic) do
      {:ok, result} -> {:classic_found, result}
      {:error, :not_found} -> create_user(identity, params, opts, @name_attempts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_user(identity, params, opts, attempts_left) do
    guest_names =
      Keyword.get_lazy(opts, :guest_names, fn ->
        Application.get_env(:pidro_server, :guest_names, GuestNames)
      end)

    with {:ok, name} <- guest_names.generate() do
      changeset =
        %User{}
        |> User.provider_registration_changeset(
          %{username: name, display_name: name},
          identity.provider,
          identity.subject
        )
        |> ClassicNameReservations.validate_changes()

      case insert_user_and_identity(changeset, identity) do
        {:ok, user} ->
          PidroServer.Friends.link_signup(
            {:ok, user},
            params["friend_slug"] || params[:friend_slug]
          )

        {:error, reason} ->
          recover_creation(identity, params, opts, attempts_left, reason)
      end
    end
  end

  defp insert_user_and_identity(changeset, identity) do
    Repo.transaction(fn ->
      with {:ok, user} <- Repo.insert(changeset),
           {:ok, user} <- UserIdentities.link(user, identity, :sign_up) do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp recover_creation(identity, params, opts, attempts_left, reason) do
    case UserIdentities.sign_in(identity) do
      {:ok, %User{} = user} ->
        {:ok, user}

      {:error, :not_found} ->
        if attempts_left > 1 and is_struct(reason, Ecto.Changeset) and
             generated_name_error?(reason) do
          create_user(identity, params, opts, attempts_left - 1)
        else
          {:error, reason}
        end

      {:error, sign_in_reason} ->
        {:error, sign_in_reason}
    end
  end

  defp generated_name_error?(changeset),
    do:
      Keyword.has_key?(changeset.errors, :username) or
        Keyword.has_key?(changeset.errors, :display_name)

  defp verified_apple_email(%{"email" => email, "email_verified" => verified})
       when is_binary(email) and email != "" and verified in [true, "true"],
       do: email

  defp verified_apple_email(_claims), do: nil

  defp apple_audience(audience) when is_binary(audience), do: audience
  defp apple_audience([audience | _rest]) when is_binary(audience), do: audience
  defp apple_audience(_audience), do: nil

  defp apple_relay?(_claims, nil), do: false

  defp apple_relay?(claims, email) do
    claims["is_private_email"] in [true, "true"] or
      String.ends_with?(String.downcase(email), "@privaterelay.appleid.com")
  end

  defp facebook_business_ids(providers, token) do
    case providers.facebook_business_ids(token) do
      {:ok, business_ids} when is_list(business_ids) ->
        if Enum.all?(business_ids, &valid_id?/1),
          do: {:ok, business_ids},
          else: {:error, :provider_unavailable}

      {:ok, _malformed} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_id?(id), do: is_binary(id) and id != ""
end

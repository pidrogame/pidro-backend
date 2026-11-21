defmodule PidroServer.Accounts.AppleTokens do
  @moduledoc """
  Sign in with Apple refresh tokens, kept so deleting an account can revoke
  them (App Review 5.1.1(v), PID-158).

  A sign-in that brings Apple's `authorization_code` exchanges it for a refresh
  token, stored encrypted on the Apple identity with the client id (the bundle
  id the identity token was issued for). Deleting the account revokes it.
  Without the Sign in with Apple key configured nothing is exchanged or revoked.
  Neither call ever fails a sign-in or a deletion; failures are logged.
  """

  require Logger

  @apple "https://appleid.apple.com"
  @salt "apple refresh token"

  @doc "Puts the encrypted refresh token for a sign-in's `authorization_code` on Apple identity attrs."
  def put_refresh_token(
        %{provider: :apple, subject: subject, issuer_app: client_id} = identity,
        params
      )
      when is_binary(client_id) do
    with code when is_binary(code) and code != "" <-
           params["authorization_code"] || params[:authorization_code],
         config when is_list(config) <- config(),
         {:ok, body} <-
           post("/auth/token", [code: code, grant_type: "authorization_code"], client_id, config),
         {:ok, token} <- refresh_token_for(body, subject) do
      Map.merge(identity, %{apple_refresh_token: encrypt(token), apple_client_id: client_id})
    else
      {:error, reason} ->
        Logger.warning("apple.exchange_failed client_id=#{client_id} reason=#{inspect(reason)}")
        identity

      _no_code_or_config ->
        identity
    end
  end

  def put_refresh_token(identity, _params), do: identity

  # The id_token comes straight from Apple over TLS, so only its subject is
  # checked: a code from another Apple ID must not be stored on this one.
  defp refresh_token_for(%{"refresh_token" => token, "id_token" => id_token}, subject)
       when is_binary(token) and is_binary(id_token) do
    with [_header, payload, _signature] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"sub" => ^subject}} <- Jason.decode(json) do
      {:ok, token}
    else
      _other -> {:error, :subject_mismatch}
    end
  end

  defp refresh_token_for(_body, _subject), do: {:error, :no_refresh_token}

  @doc "Revokes an identity's stored refresh token. Logs `apple.revoke_failed` on any failure."
  def revoke(%{apple_refresh_token: encrypted, apple_client_id: client_id, user_id: user_id}) do
    with config when is_list(config) <- config() || {:error, :not_configured},
         {:ok, token} <- Plug.Crypto.decrypt(secret(), @salt, encrypted, max_age: :infinity),
         {:ok, _body} <-
           post(
             "/auth/revoke",
             [token: token, token_type_hint: "refresh_token"],
             client_id,
             config
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "apple.revoke_failed user_id=#{user_id} client_id=#{client_id} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  defp config do
    config = Application.get_env(:pidro_server, __MODULE__, [])

    if Enum.all?([:key_id, :team_id, :private_key], &(config[&1] not in [nil, ""])),
      do: config
  end

  defp post(path, form, client_id, config) do
    form = [client_id: client_id, client_secret: client_secret(client_id, config)] ++ form

    options = [
      url: @apple <> path,
      form: form,
      connect_options: [timeout: 5_000],
      receive_timeout: 5_000
    ]

    case Req.post(Keyword.merge(options, Keyword.get(config, :req_options, []))) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: %{"error" => error}}} -> {:error, {status, error}}
      {:ok, %{status: status}} -> {:error, status}
      {:error, exception} -> {:error, exception.__struct__}
    end
  rescue
    # A malformed key raises; its message may hold key material, so log only the kind.
    exception -> {:error, exception.__struct__}
  catch
    :exit, _reason -> {:error, :exit}
  end

  # Apple's client secret: an ES256 JWT signed with the Sign in with Apple key.
  defp client_secret(client_id, config) do
    now = System.os_time(:second)
    header = %{"alg" => "ES256", "kid" => config[:key_id]}

    claims = %{
      "iss" => config[:team_id],
      "iat" => now,
      "exp" => now + 300,
      "aud" => @apple,
      "sub" => client_id
    }

    [entry] = :public_key.pem_decode(config[:private_key])
    key = :public_key.pem_entry_decode(entry)
    message = encode(Jason.encode!(header)) <> "." <> encode(Jason.encode!(claims))
    der = :public_key.sign(message, :sha256, key)
    {_, r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    message <>
      "." <> encode(<<r::unsigned-big-integer-size(256), s::unsigned-big-integer-size(256)>>)
  end

  defp encode(value), do: Base.url_encode64(value, padding: false)

  defp encrypt(token), do: Plug.Crypto.encrypt(secret(), @salt, token)

  defp secret,
    do: Application.fetch_env!(:pidro_server, PidroServerWeb.Endpoint)[:secret_key_base]
end

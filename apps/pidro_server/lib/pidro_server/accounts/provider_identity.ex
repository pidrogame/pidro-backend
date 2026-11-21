defmodule PidroServer.Accounts.ProviderIdentity do
  @moduledoc "Validates Apple and Facebook credentials against their providers."

  @apple_issuer "https://appleid.apple.com"
  @facebook_issuer "https://www.facebook.com"

  alias PidroServer.Accounts.{FacebookNonce, JwksCache}

  def apple(identity_token) when is_binary(identity_token) do
    with {:ok, header, claims, signed, signature} <- decode_jwt(identity_token),
         true <- header["alg"] == "RS256" or {:error, :invalid_credentials},
         {:ok, key} <- apple_key(header["kid"]),
         true <- verify_signature(key, signed, signature) or {:error, :invalid_credentials},
         :ok <- validate_apple_claims(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def apple(_identity_token), do: {:error, :invalid_credentials}

  def facebook(access_token) when is_binary(access_token) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)
    app_id = Keyword.fetch!(config, :facebook_app_id)

    with {:ok, %{"data" => %{"is_valid" => true, "app_id" => ^app_id} = debug}} <-
           facebook_get("/debug_token",
             input_token: access_token,
             access_token: app_id <> "|" <> Keyword.fetch!(config, :facebook_app_secret)
           ),
         {:ok, %{"id" => id} = profile} <-
           facebook_get("/me", access_token: access_token, fields: "email"),
         true <- (is_binary(id) and id == debug["user_id"]) or {:error, :invalid_credentials} do
      {:ok, %{subject: id, issuer_app: app_id, email: facebook_email(profile)}}
    else
      {:ok, _invalid} -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  def facebook(_access_token), do: {:error, :invalid_credentials}

  def facebook_limited(authentication_token, nonce)
      when is_binary(authentication_token) and is_binary(nonce) and nonce != "" do
    with {:ok, header, claims, signed, signature} <- decode_jwt(authentication_token),
         true <- header["alg"] == "RS256" or {:error, :invalid_credentials},
         {:ok, key} <- provider_key(:facebook, header["kid"]),
         true <- verify_signature(key, signed, signature) or {:error, :invalid_credentials},
         {:ok, expires_at} <- validate_facebook_claims(claims, nonce),
         :ok <- FacebookNonce.consume(nonce, expires_at) do
      {:ok,
       %{
         subject: claims["sub"],
         issuer_app: claims["aud"],
         email: facebook_email(claims)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def facebook_limited(_authentication_token, _nonce), do: {:error, :invalid_credentials}

  # Meta's data-deletion callback (PID-162) sends `<signature>.<payload>`, both
  # base64url; the signature is the HMAC-SHA256 of the encoded payload with the
  # app secret. Answers the app-scoped Facebook user id, our identity's subject.
  def facebook_signed_request(signed_request) when is_binary(signed_request) do
    secret =
      :pidro_server |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:facebook_app_secret)

    with true <- secret != "",
         [encoded_signature, encoded_payload] <- String.split(signed_request, "."),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         expected = :crypto.mac(:hmac, :sha256, secret, encoded_payload),
         true <- Plug.Crypto.secure_compare(signature, expected),
         {:ok, payload_json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, %{"algorithm" => "HMAC-SHA256", "user_id" => user_id}}
         when is_binary(user_id) and user_id != "" <- Jason.decode(payload_json) do
      {:ok, user_id}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  def facebook_signed_request(_signed_request), do: {:error, :invalid_credentials}

  def facebook_business_ids(access_token) when is_binary(access_token) do
    facebook_business_ids_page(access_token, nil, %{}, [])
  end

  defp facebook_business_ids_page(access_token, after_cursor, seen_cursors, ids) do
    params =
      [access_token: access_token]
      |> then(fn params ->
        if after_cursor, do: Keyword.put(params, :after, after_cursor), else: params
      end)

    case facebook_get("/me/ids_for_business", params) do
      {:ok, %{"data" => identities} = body} when is_list(identities) ->
        with {:ok, page_ids} <- identity_ids(identities) do
          ids = ids ++ page_ids

          case next_cursor(body) do
            nil ->
              {:ok, ids}

            cursor when is_binary(cursor) ->
              if Map.has_key?(seen_cursors, cursor) do
                {:error, :provider_unavailable}
              else
                facebook_business_ids_page(
                  access_token,
                  cursor,
                  Map.put(seen_cursors, cursor, true),
                  ids
                )
              end

            :missing ->
              {:error, :provider_unavailable}
          end
        end

      {:ok, _invalid} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_jwt(token) do
    with [encoded_header, encoded_claims, encoded_signature] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(encoded_header, padding: false),
         {:ok, claims_json} <- Base.url_decode64(encoded_claims, padding: false),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(header_json),
         {:ok, claims} when is_map(claims) <- Jason.decode(claims_json) do
      {:ok, header, claims, encoded_header <> "." <> encoded_claims, signature}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp apple_key(kid) when is_binary(kid) do
    provider_key(:apple, kid)
  end

  defp apple_key(_kid), do: {:error, :invalid_credentials}

  defp provider_key(provider, kid) when provider in [:apple, :facebook] and is_binary(kid) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)

    with {:ok, keys} <-
           JwksCache.fetch(
             Keyword.fetch!(config, jwks_url_key(provider)),
             Keyword.get(config, :req_options, []),
             Keyword.get(config, :jwks_cache_ttl_ms, 300_000)
           ) do
      case Enum.find(keys, fn
             %{"kid" => key_kid, "kty" => "RSA"} -> key_kid == kid
             _invalid -> false
           end) do
        %{"n" => modulus, "e" => exponent}
        when is_binary(modulus) and is_binary(exponent) ->
          rsa_key(modulus, exponent)

        _missing ->
          {:error, :invalid_credentials}
      end
    end
  end

  defp provider_key(_provider, _kid), do: {:error, :invalid_credentials}

  defp jwks_url_key(:apple), do: :apple_jwks_url
  defp jwks_url_key(:facebook), do: :facebook_jwks_url

  defp rsa_key(modulus, exponent) do
    with {:ok, modulus} <- Base.url_decode64(modulus, padding: false),
         {:ok, exponent} <- Base.url_decode64(exponent, padding: false) do
      {:ok, {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_signature(key, signed, signature) do
    :public_key.verify(signed, :sha256, signature, key)
  rescue
    _error -> false
  end

  defp validate_apple_claims(claims) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)
    audience = Keyword.fetch!(config, :apple_audience)
    now = System.system_time(:second)

    if claims["iss"] == @apple_issuer and audience?(claims["aud"], audience) and
         is_integer(claims["exp"]) and claims["exp"] > now and
         is_binary(claims["sub"]) and claims["sub"] != "" do
      :ok
    else
      {:error, :invalid_credentials}
    end
  end

  defp validate_facebook_claims(claims, nonce) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)
    audience = Keyword.fetch!(config, :facebook_app_id)
    now = System.system_time(:second)

    if claims["iss"] == @facebook_issuer and claims["aud"] == audience and
         is_integer(claims["exp"]) and claims["exp"] > now and
         is_binary(claims["sub"]) and claims["sub"] != "" and claims["nonce"] == nonce do
      DateTime.from_unix(claims["exp"])
    else
      {:error, :invalid_credentials}
    end
  end

  # `expected` is one bundle ID or a list: the store app and the side-by-side
  # Beta (com.oneapps.pidro.beta) both sign in against this backend.
  defp audience?(audience, expected) when is_list(expected),
    do: Enum.any?(expected, &audience?(audience, &1))

  defp audience?(audience, expected) when is_binary(audience), do: audience == expected
  defp audience?(audiences, expected) when is_list(audiences), do: expected in audiences
  defp audience?(_audience, _expected), do: false

  defp facebook_get(path, params) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)
    base_url = Keyword.fetch!(config, :facebook_graph_url)
    options = [url: base_url <> path, params: params, receive_timeout: 5_000]

    case Req.get(Keyword.merge(options, Keyword.get(config, :req_options, []))) do
      {:ok, %{status: 200, body: body}} -> json_body(body)
      {:ok, %{status: status}} when status in 400..499 -> {:error, :invalid_credentials}
      _response -> {:error, :provider_unavailable}
    end
  end

  # Graph answers server-side calls with `content-type: text/javascript`, so Req
  # leaves the JSON undecoded. Decode it here; anything else is an outage.
  defp json_body(body) when is_map(body), do: {:ok, body}

  defp json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _invalid -> {:error, :provider_unavailable}
    end
  end

  defp json_body(_body), do: {:error, :provider_unavailable}

  defp facebook_email(%{"email" => email}) when is_binary(email) and email != "", do: email
  defp facebook_email(_profile), do: nil

  defp identity_ids(identities) do
    Enum.reduce_while(identities, {:ok, []}, fn
      %{"id" => id}, {:ok, ids} when is_binary(id) and id != "" ->
        {:cont, {:ok, [id | ids]}}

      _invalid, _ids ->
        {:halt, {:error, :provider_unavailable}}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp next_cursor(%{"paging" => paging}) when is_map(paging) do
    case Map.fetch(paging, "next") do
      :error ->
        nil

      {:ok, next} when is_binary(next) and next != "" ->
        case get_in(paging, ["cursors", "after"]) do
          cursor when is_binary(cursor) and cursor != "" -> cursor
          _missing -> :missing
        end

      {:ok, _malformed} ->
        :missing
    end
  end

  defp next_cursor(%{"paging" => _malformed}), do: :missing
  defp next_cursor(_body), do: nil
end

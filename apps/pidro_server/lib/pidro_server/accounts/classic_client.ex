defmodule PidroServer.Accounts.ClassicClient do
  @moduledoc "Read-only client for Classic account ownership and profile data."

  @callback verify_password(String.t(), String.t()) ::
              {:ok, map()}
              | {:error, :invalid_credentials | :account_inactive | :provider_unavailable}
  @callback lookup(:email | :fbid | :login | :id, String.t() | integer()) ::
              {:ok, map()} | {:error, :not_found | :ambiguous | :provider_unavailable}

  def verify_password(login, password) do
    request(:post, "/internal/claims/verify_password", json: %{login: login, password: password})
    |> verified_profile()
  end

  def lookup(field, value) when field in [:email, :fbid, :login] do
    request(:get, "/internal/claims/lookup", params: [{field, value}])
    |> lookup_result()
  end

  # The Classic id of an account already linked here; no client chooses it.
  # The Premium carry-over retries on its own schedule, so one try only.
  def lookup(:id, classic_user_id) do
    request(:get, "/internal/claims/lookup", params: [id: classic_user_id], retry: false)
    |> lookup_result()
  end

  defp request(method, path, options) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)

    options =
      Keyword.merge(
        [
          method: method,
          url: Keyword.fetch!(config, :base_url) <> path,
          auth: {:bearer, Keyword.fetch!(config, :secret)},
          receive_timeout: 5_000
        ],
        options
      )

    Req.request(Keyword.merge(options, Keyword.get(config, :req_options, [])))
  end

  # Classic answers 401 for a wrong login or password and 403 for an account
  # that exists but is switched off. A 401 caused by a bad shared secret looks
  # the same from here; ops checks it with a lookup (see the deploy runbook).
  defp verified_profile({:ok, %{status: 200, body: %{"classic" => profile}}})
       when is_map(profile),
       do: {:ok, normalize(profile)}

  defp verified_profile({:ok, %{status: status}}) when status in [401, 404],
    do: {:error, :invalid_credentials}

  defp verified_profile({:ok, %{status: 403}}), do: {:error, :account_inactive}
  defp verified_profile(_response), do: {:error, :provider_unavailable}

  defp lookup_result({:ok, %{status: 200, body: %{"classic" => profile}}}) when is_map(profile),
    do: {:ok, normalize(profile)}

  defp lookup_result({:ok, %{status: 404}}), do: {:error, :not_found}
  defp lookup_result({:ok, %{status: 409}}), do: {:error, :ambiguous}
  defp lookup_result(_response), do: {:error, :provider_unavailable}

  @doc """
  Flattens Classic's `/internal/claims/*` profile into the keys the claim flow
  reads. Classic nests games-played sources under `games` and premium under
  `premium`, and calls the pre-2017 display name `first_name`.
  """
  def normalize(profile) when is_map(profile) do
    games = Map.get(profile, "games") || %{}
    premium = Map.get(profile, "premium") || %{}

    %{
      "id" => profile["id"],
      "username" => profile["username"],
      "firstname" => profile["first_name"],
      "email" => profile["email"],
      "fbid" => profile["fbid"],
      "level" => profile["level"],
      "xp" => profile["xp"],
      "played_games" => games["legacy_played_games"],
      "victories" => games["legacy_victories"],
      "losses" => games["legacy_losses"],
      "total_game" => games["total_game"],
      "win_game" => games["win_game"],
      "lost_game" => games["lost_game"],
      "xpoints_count" => games["games_logged"],
      "started" => games["games_started"],
      "ended" => games["games_ended"],
      "inserted_at" => profile["member_since"],
      "premium_until" => premium["until"],
      "premium_product" => premium["product"],
      "premium_store" => premium["store"],
      "account_deleted" => get_in(profile, ["account", "deleted"]),
      "account_visible" => get_in(profile, ["account", "visible"]),
      "badges" => profile["badges"] || []
    }
    |> Map.merge(Map.take(profile, ["friend_ids", "friended_by_ids", "blocked_ids"]))
  end
end

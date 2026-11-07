defmodule PidroServer.RevenueCat do
  @moduledoc """
  RevenueCat, which holds the App Store and Google Play truth about Premium
  (PID-125). Off unless both `REVENUECAT_SECRET_KEY` and
  `REVENUECAT_WEBHOOK_SECRET` are set.

  `get_subscriber/1` creates the customer when it does not exist, so it is
  only ever called with one of our own user ids, never in bulk.
  """

  require Logger

  @base_url "https://api.revenuecat.com/v1/subscribers/"

  @doc "Whether both the secret key and the webhook secret are set."
  @spec configured?() :: boolean()
  def configured?, do: config()[:secret_key] != nil and config()[:webhook_secret] != nil

  @doc "The webhook's bearer secret, or nil."
  @spec webhook_secret() :: String.t() | nil
  def webhook_secret, do: config()[:webhook_secret]

  @doc "The `subscriber` object for one app user id."
  @spec get_subscriber(String.t()) :: {:ok, map()} | {:error, term()}
  def get_subscriber(app_user_id) do
    case request(:get, app_user_id, nil) do
      {:ok, %{"subscriber" => subscriber}} when is_map(subscriber) -> {:ok, subscriber}
      {:ok, _body} -> {:error, :bad_answer}
      error -> error
    end
  end

  @doc "Grants a promotional entitlement that ends at `end_time_ms`."
  @spec grant_promotional(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def grant_promotional(app_user_id, entitlement, end_time_ms) do
    path = "#{app_user_id}/entitlements/#{entitlement}/promotional"

    case request(:post, path, %{end_time_ms: end_time_ms}) do
      {:ok, _body} -> :ok
      error -> error
    end
  end

  defp request(method, path, json) do
    config = config()

    [
      method: method,
      url: @base_url <> path,
      auth: {:bearer, config[:secret_key]},
      receive_timeout: 10_000,
      retry: false
    ]
    |> then(&if(json, do: Keyword.put(&1, :json, json), else: &1))
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.request()
    |> case do
      # 201 too: a grant answers 201, and so does a GET that created the customer.
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("RevenueCat #{method} answered HTTP #{status}")
        {:error, {:revenuecat_status, status}}

      {:error, reason} ->
        Logger.warning("RevenueCat #{method} failed: #{inspect(reason)}")
        {:error, :revenuecat_unreachable}
    end
  end

  defp config, do: Application.get_env(:pidro_server, __MODULE__, [])
end

defmodule PidroServer.RevenueCat do
  @moduledoc """
  RevenueCat, which holds the App Store and Google Play truth about Premium
  (PID-125). Off unless both `REVENUECAT_SECRET_KEY` and
  `REVENUECAT_WEBHOOK_SECRET` are set.
  """

  @doc "Whether both the secret key and the webhook secret are set."
  @spec configured?() :: boolean()
  def configured?, do: config()[:secret_key] != nil and config()[:webhook_secret] != nil

  defp config, do: Application.get_env(:pidro_server, __MODULE__, [])
end

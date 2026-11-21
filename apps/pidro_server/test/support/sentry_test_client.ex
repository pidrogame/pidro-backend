defmodule PidroServer.SentryTestClient do
  @moduledoc "Sentry's HTTP client in tests: hands each envelope to the listening test, no network."
  @behaviour Sentry.HTTPClient

  def listen, do: :persistent_term.put(__MODULE__, self())

  @impl true
  def post(_url, _headers, body) do
    send(:persistent_term.get(__MODULE__), {:sentry_envelope, IO.iodata_to_binary(body)})
    {:ok, 200, [], ~s({"id":"0"})}
  end
end

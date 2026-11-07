defmodule PidroServer.Push.Expo do
  @moduledoc """
  Expo's push API. Sends with `EXPO_ACCESS_TOKEN` when it is set, and without
  it otherwise, which Expo allows while the project does not require one.
  """

  @url "https://exp.host/--/api/v2/push"

  @doc "Sends up to 100 messages; the tickets come back in the same order."
  @spec send_messages([map()]) :: {:ok, [map()]} | {:error, term()}
  def send_messages(messages), do: post("/send", messages)

  @doc "The receipts Expo has for these ticket ids, by id; ids without one yet are absent."
  @spec get_receipts([String.t()]) :: {:ok, map()} | {:error, term()}
  def get_receipts(ids), do: post("/getReceipts", %{ids: ids})

  defp post(path, body) do
    config = Application.get_env(:pidro_server, __MODULE__, [])

    headers =
      [{"accept", "application/json"}, {"content-type", "application/json"}] ++
        if config[:access_token],
          do: [{"authorization", "Bearer #{config[:access_token]}"}],
          else: []

    [
      method: :post,
      url: @url <> path,
      headers: headers,
      json: body,
      receive_timeout: 15_000,
      retry: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.request()
    |> case do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: 200}} -> {:error, :bad_response}
      {:ok, %{status: status, body: body}} -> {:error, {:status, status, codes(body)}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp codes(%{"errors" => errors}) when is_list(errors), do: Enum.map(errors, & &1["code"])
  defp codes(_body), do: []
end

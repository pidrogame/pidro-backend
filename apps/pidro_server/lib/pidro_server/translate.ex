defmodule PidroServer.Translate do
  @moduledoc """
  Translates a news post's English into casual Swedish with Claude (PID-349),
  for `/admin/news` to fill in. Without `ANTHROPIC_API_KEY` it is off.
  """

  require Logger

  @callback to_swedish(String.t(), String.t()) ::
              {:ok, %{title: String.t(), body: String.t()}} | {:error, term()}

  @system """
  You translate news posts for Pidro, a card game app, from English into Swedish.

  Pidro's Swedish-speaking players are mostly Finland-Swedish card players, and many of them are older.

  Write natural, casual, friendly Swedish, the way a friend from the card table would say it. Not stiff, and not marketing.

  Use short sentences. Keep the meaning and every line break.

  Keep the word "Pidro" as it is.

  When a post names a screen in the app, use the app's own Swedish word for it: Inställningar (Settings), Ljud (Sound), Berätta för oss (Tell us), Nyheter (News), Vänner (Friends).

  Use no emoji unless the English has them.

  You get the post as JSON with "title" and "body". Answer with only a JSON object of the same shape, {"title": "…", "body": "…"}, and nothing else. Line breaks in the body are \\n.
  """

  @doc "Whether a key is set, so translation can run."
  @spec enabled?() :: boolean()
  def enabled?, do: config()[:api_key] != nil

  @doc "The Swedish title and body for an English post, or an error."
  def to_swedish(title, body) do
    config = config()

    [
      method: :post,
      url: "https://api.anthropic.com/v1/messages",
      headers: [{"x-api-key", config[:api_key]}, {"anthropic-version", "2023-06-01"}],
      json: %{
        model: "claude-sonnet-5-5",
        max_tokens: 1_000,
        system: @system,
        messages: [%{role: "user", content: Jason.encode!(%{title: title, body: body})}]
      },
      receive_timeout: 30_000,
      retry: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.request()
    |> answer()
  end

  # Strict: one text block holding exactly the JSON asked for.
  defp answer({:ok, %{status: 200, body: body}}) do
    with %{"content" => [%{"type" => "text", "text" => text}]} <- body,
         {:ok, %{"title" => title, "body" => body}} when is_binary(title) and is_binary(body) <-
           Jason.decode(text) do
      {:ok, %{title: title, body: body}}
    else
      _ ->
        Logger.warning("Translation answer was not the JSON asked for")
        {:error, :bad_answer}
    end
  end

  defp answer({:ok, %{status: status}}) do
    Logger.warning("Translation failed with HTTP #{status}")
    {:error, {:status, status}}
  end

  defp answer({:error, reason}) do
    Logger.warning("Translation failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp config, do: Application.get_env(:pidro_server, __MODULE__, [])
end

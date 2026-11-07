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

  Use short sentences. Keep the meaning, every line break, Markdown bold and link destinations.

  Keep the word "Pidro" as it is.

  When a post names a screen in the app, use the app's own Swedish word for it: Inställningar (Settings), Ljud (Sound), Berätta för oss (Tell us), Nyheter (News), Vänner (Friends).

  Use no emoji unless the English has them.

  You get the post as JSON with "title" and "body", and optionally "eyebrow" and "button_label". Answer with only a JSON object of the same shape and nothing else. Translate every supplied field. Line breaks in the body are \\n.
  """

  @doc "Whether a key is set, so translation can run."
  @spec enabled?() :: boolean()
  def enabled?, do: config()[:api_key] != nil

  @doc "The Swedish title and body for an English post, or an error."
  def to_swedish(title, body, extra \\ %{}) do
    config = config()
    fields = Map.merge(%{title: title, body: body}, extra)

    [
      method: :post,
      url: "https://api.anthropic.com/v1/messages",
      headers: [{"x-api-key", config[:api_key]}, {"anthropic-version", "2023-06-01"}],
      json: %{
        model: "claude-sonnet-5-5",
        # The model thinks before it answers, and the thinking counts here.
        max_tokens: 2_000,
        system: @system,
        messages: [%{role: "user", content: Jason.encode!(fields)}]
      },
      receive_timeout: 30_000,
      retry: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.request()
    |> answer(Map.keys(fields))
  end

  # Strict: the first text block, after any thinking, holds exactly the JSON
  # asked for.
  defp answer({:ok, %{status: 200, body: %{"content" => content} = answer}}, fields)
       when is_list(content) do
    with %{"text" => text} when is_binary(text) <-
           Enum.find(content, &match?(%{"type" => "text"}, &1)) ||
             {:no_text, answer["stop_reason"]},
         {:ok, values} when is_map(values) <- Jason.decode(text),
         true <- Enum.all?(fields, &is_binary(values[Atom.to_string(&1)])) do
      {:ok, Map.new(fields, &{&1, values[Atom.to_string(&1)]})}
    else
      {:no_text, "max_tokens"} ->
        Logger.warning("Translation ran out of tokens before it answered")
        {:error, :max_tokens}

      _ ->
        Logger.warning("Translation answer was not the JSON asked for")
        {:error, :bad_answer}
    end
  end

  defp answer({:ok, %{status: 200}}, _fields) do
    Logger.warning("Translation answer was not the JSON asked for")
    {:error, :bad_answer}
  end

  defp answer({:ok, %{status: status}}, _fields) do
    Logger.warning("Translation failed with HTTP #{status}")
    {:error, {:status, status}}
  end

  defp answer({:error, reason}, _fields) do
    Logger.warning("Translation failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp config, do: Application.get_env(:pidro_server, __MODULE__, [])
end

defmodule PidroServer.Moderation do
  @moduledoc """
  Whether a typed text or a new username may be shown to other players
  (PID-84), against the one word list in `priv/moderation/words.txt`
  (English, Swedish, Finnish).

  The text is NFKC-normalized and lowercased, simple letter swaps are undone
  (`sh1t`, `$hit`), a letter held down is let go (`fuuuck`) and letters
  spaced apart are joined (`f u c k`, `f.u.c.k`). Then only whole words
  count, so a clean name that contains a listed word, like Kukkonen or
  Scunthorpe, passes. Text that is not valid UTF-8 or longer than 1,000
  bytes is not allowed.
  """

  @external_resource words_path = Path.expand("../../priv/moderation/words.txt", __DIR__)

  @words words_path
         |> File.read!()
         |> String.split("\n", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
         |> MapSet.new()

  # A digit or sign standing in for a letter; "1" and "|" may be an i or an l.
  @swaps %{
    "0" => "o",
    "1" => "i",
    "3" => "e",
    "4" => "a",
    "5" => "s",
    "7" => "t",
    "8" => "b",
    "@" => "a",
    "$" => "s",
    "!" => "i",
    "|" => "i",
    "€" => "e"
  }
  @swaps_l Map.merge(@swaps, %{"1" => "l", "|" => "l"})

  @doc """
  True unless `text` holds a listed word.

      iex> PidroServer.Moderation.allowed?("Hyvä peli!")
      true
      iex> PidroServer.Moderation.allowed?("v1ttu")
      false
  """
  @spec allowed?(String.t()) :: boolean()
  def allowed?(text) when is_binary(text) and byte_size(text) <= 1_000 do
    if String.valid?(text) do
      text = text |> :unicode.characters_to_nfkc_binary() |> String.downcase()
      not Enum.any?([text, swap(text, @swaps), swap(text, @swaps_l)], &listed?/1)
    else
      false
    end
  end

  def allowed?(_text), do: false

  defp swap(text, swaps), do: text |> String.graphemes() |> Enum.map_join(&Map.get(swaps, &1, &1))

  defp listed?(text) do
    words = String.split(text, ~r/[^\p{L}]+/u, trim: true)

    Enum.any?(words ++ spaced(words), fn word ->
      Enum.any?([word | held(word)], &(&1 in @words))
    end)
  end

  # Runs of single letters, joined: "f u c k" -> "fuck".
  defp spaced(words) do
    words
    |> Enum.chunk_by(&(String.length(&1) == 1))
    |> Enum.filter(&match?([<<_::utf8>>, _ | _], &1))
    |> Enum.map(&Enum.join/1)
  end

  # A letter held down three times or more, as one or two: "fuuuuck" ->
  # "fuck", "vitttu" -> "vittu". A doubled letter is left alone, so
  # "horror" and "kyss" stay themselves.
  defp held(word) do
    for once <- ["\\1", "\\1\\1"], do: String.replace(word, ~r/(\p{L})\1{2,}/u, once)
  end
end

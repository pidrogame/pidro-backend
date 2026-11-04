defmodule PidroServer.GameArchive.Serialization do
  @moduledoc "Version 1 data-only JSON. Never reconstructs executable Erlang terms."

  @doc "Encodes game facts, rejecting runtime resources rather than inspecting them."
  @spec encode(term()) :: term()
  def encode(nil), do: nil
  def encode(value) when is_boolean(value) or is_binary(value) or is_float(value), do: value
  def encode(value) when is_integer(value) and abs(value) <= 9_007_199_254_740_991, do: value
  def encode(value) when is_integer(value), do: %{"$integer" => Integer.to_string(value)}
  def encode(value) when is_atom(value), do: Atom.to_string(value)
  def encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode(%MapSet{} = value), do: %{"$set" => encode(MapSet.to_list(value))}

  def encode(%module{} = value) do
    value |> Map.from_struct() |> encode() |> Map.put("$struct", Atom.to_string(module))
  end

  def encode(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key(key), encode(item)} end)
  end

  def encode(value) when is_tuple(value), do: %{"$tuple" => encode(Tuple.to_list(value))}
  def encode(value) when is_list(value), do: encode_list(value, [])
  def encode(_), do: raise(ArgumentError, "unsupported archive value")

  @game_structs Map.new(
                  [
                    Pidro.Core.Types.GameState,
                    Pidro.Core.Types.Player,
                    Pidro.Core.Types.Trick,
                    Pidro.Core.Types.Bid
                  ],
                  &{Atom.to_string(&1), &1}
                )

  @doc """
  Decodes an encoded game state or engine events back into engine terms.

  A game state holds no strings, so every string is an existing atom; only the
  engine's own structs are rebuilt. Anything else raises.
  """
  @spec decode_game(term()) :: term()
  def decode_game(nil), do: nil
  def decode_game(value) when is_boolean(value) or is_number(value), do: value
  def decode_game(value) when is_binary(value), do: String.to_existing_atom(value)
  def decode_game(%{"$integer" => value}), do: String.to_integer(value)
  def decode_game(%{"$set" => items}), do: MapSet.new(decode_game(items))
  def decode_game(%{"$tuple" => items}), do: items |> decode_game() |> List.to_tuple()

  def decode_game(%{"$improper_list" => head, "$tail" => tail}),
    do: decode_game(head) ++ decode_game(tail)

  def decode_game(%{"$struct" => module} = value),
    do:
      struct!(Map.fetch!(@game_structs, module), value |> Map.delete("$struct") |> decode_game())

  def decode_game(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {String.to_existing_atom(key), decode_game(item)} end)

  def decode_game(value) when is_list(value), do: Enum.map(value, &decode_game/1)

  defp key(value) when is_atom(value), do: Atom.to_string(value)
  defp key(value) when is_binary(value), do: value
  defp key(value) when is_integer(value), do: Integer.to_string(value)
  defp key(_), do: raise(ArgumentError, "unsupported archive key")

  defp encode_list([], acc), do: Enum.reverse(acc)
  defp encode_list([head | tail], acc), do: encode_list(tail, [encode(head) | acc])

  defp encode_list(tail, acc),
    do: %{"$improper_list" => Enum.reverse(acc), "$tail" => encode(tail)}
end

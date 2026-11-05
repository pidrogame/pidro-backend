defmodule PidroServer.Games.UnexpectedMessage do
  @moduledoc false
  require Logger

  # One debug line per envelope for each subscriber process, never its payload.
  def report_once(subscriber, message) do
    {tag, arity} = envelope(message)
    key = {__MODULE__, subscriber, tag, arity}

    unless Process.get(key) do
      Process.put(key, true)

      Logger.debug(
        "#{inspect(subscriber)} ignored unexpected message tag=#{inspect(tag)} arity=#{arity}"
      )
    end

    :telemetry.execute(
      [:pidro_server, :game_topic, :unexpected_message],
      %{count: 1},
      %{subscriber: subscriber, tag: tag, arity: arity}
    )

    :ok
  end

  # Report the envelope, never the payload (which can contain private hands or
  # account data). Keep room identifiers out of metric labels.
  def report(subscriber, message) do
    {tag, arity} = envelope(message)

    Logger.warning(
      "#{inspect(subscriber)} ignored unexpected message tag=#{inspect(tag)} arity=#{arity}"
    )

    :telemetry.execute(
      [:pidro_server, :game_topic, :unexpected_message],
      %{count: 1},
      %{subscriber: subscriber, tag: tag, arity: arity}
    )
  end

  defp envelope(message) when is_atom(message), do: {message, 0}

  defp envelope(message) when is_tuple(message) and tuple_size(message) > 0 do
    tag = if is_atom(elem(message, 0)), do: elem(message, 0), else: :untagged
    {tag, tuple_size(message)}
  end

  defp envelope(_message), do: {:untagged, 0}
end

defmodule PidroServer.Diagnostics do
  @moduledoc "Bounded, payload-free diagnostics. Never pass game state or client payloads."
  require Logger

  @identifiers ~w(room_code game_instance_id user_id seat action_id report_id app_version app_build platform server_build action outcome error_code reason join_type)a
  @numbers ~w(state_revision observed_revision duration_ms)a

  @doc "Optional client correlation token: ASCII only, at most 64 bytes; invalid values disappear."
  def token(value) when is_binary(value) and byte_size(value) in 1..256 do
    if Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value),
      do: binary_part(value, 0, min(byte_size(value), 64))
  end

  def token(_), do: nil

  def action_id(value) when is_binary(value) and byte_size(value) in 1..256 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value),
      do: binary_part(value, 0, min(byte_size(value), 64))
  end

  def action_id(_), do: nil

  def fields(fields) when is_map(fields) do
    Enum.reduce(fields, %{}, fn
      {:action_id, value}, acc ->
        if safe = action_id(value), do: Map.put(acc, :action_id, safe), else: acc

      {key, value}, acc when key in @identifiers ->
        value = if is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value
        if safe = token(value), do: Map.put(acc, key, safe), else: acc

      {key, value}, acc when key in @numbers and is_integer(value) and value >= 0 ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  def fields(_), do: %{}

  def emit(event, data, level \\ :info) do
    data =
      data
      |> fields()
      |> Map.put(:event, token(Atom.to_string(event)))
      |> Map.put(
        :server_build,
        token(Application.get_env(:pidro_server, :server_build, "unknown"))
      )

    Logger.log(level, "#{data.event} room=#{data[:room_code]}", diagnostic: data)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

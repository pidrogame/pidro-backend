defmodule PidroServer.RoomManagerCase do
  @moduledoc false

  alias PidroServer.Games.RoomManager

  @spec cleanup() :: :ok
  def cleanup do
    if Process.whereis(RoomManager), do: RoomManager.reset_for_test(), else: :ok
  end

  @spec expire_phase(String.t(), atom(), atom()) :: {:ok, RoomManager.Room.t()}
  def expire_phase(room_code, position, phase) do
    {:ok, room} = RoomManager.get_room(room_code)
    timer_ref = Map.fetch!(room.phase_timers, position)

    Process.cancel_timer(timer_ref)
    send(RoomManager, {:timeout, timer_ref, {phase, room_code, position}})

    RoomManager.get_room(room_code)
  end
end

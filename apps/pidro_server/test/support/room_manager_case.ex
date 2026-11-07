defmodule PidroServer.RoomManagerCase do
  @moduledoc false

  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.RoomManager

  # A bot that dies without BotManager.stop_bot (the reset tears rooms down)
  # keeps its {room_code, position} slot, and room codes repeat across the
  # suite: free those slots, or a later room could not seat a bot there.
  @spec cleanup() :: :ok
  def cleanup do
    if Process.whereis(RoomManager), do: RoomManager.reset_for_test()

    if :ets.whereis(:pidro_bots) != :undefined do
      for {{code, position}, pid} <- :ets.tab2list(:pidro_bots),
          not Process.alive?(pid),
          do: BotManager.stop_bot(code, position)
    end

    :ok
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

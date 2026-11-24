defmodule PidroServerWeb.Dev.LiveGameBadge do
  @moduledoc false
  use PidroServerWeb, :live_component

  alias PidroServer.Games.RoomManager

  @impl true
  def mount(socket), do: {:ok, socket |> assign(:count, 0) |> refresh()}

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, refresh(socket)}
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  defp refresh(socket) do
    start_async(socket, :playing_rooms, &RoomManager.count_playing_rooms/0)
  end

  @impl true
  def handle_async(:playing_rooms, result, socket) do
    count =
      case result do
        {:ok, count} -> count
        {:exit, _reason} -> 0
      end

    send_update_after(socket.assigns.myself, %{refresh: true}, 5_000)
    {:noreply, assign(socket, :count, count)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id} hidden={@count == 0} class="ml-auto">
      <span
        :if={@count > 0}
        class="inline-flex min-w-5 justify-center rounded-full bg-emerald-100 px-1.5 text-xs/5 font-semibold tabular-nums text-emerald-800"
      >
        {@count}<span class="sr-only"> in progress</span>
      </span>
    </span>
    """
  end
end

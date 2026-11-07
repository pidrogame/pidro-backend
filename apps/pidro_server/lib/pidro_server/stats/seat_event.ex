defmodule PidroServer.Stats.SeatEvent do
  @moduledoc """
  One thing that happened to a player's seat at a live table, for the beta
  report. Kinds:

    * `drop` - the player's connection went during a game; a loss the server
      only learns of on the rejoin is recorded then, with the app's reason
    * `return` - the player was back after a drop
    * `turn` - the player acted on a timed turn; `elapsed_ms` is how long it took
    * `timeout` - the turn clock ran out on a connected player and the server
      played for them; `metadata` holds the `action`
    * `bot_took_seat` - a substitute bot took the seat; `metadata` holds the
      `trigger`: `drop` or `missed_turns`
    * `seat_taken_back` - the player took the seat back from the bot
    * `away_play` - a move made for the seat while its player was away;
      `metadata` holds the `actor` (`timer` or `bot`) and the `action`
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(join drop return turn timeout bot_took_seat seat_taken_back away_play)

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "seat_events" do
    field :user_id, :string
    field :room_code, :string
    field :kind, :string
    field :elapsed_ms, :integer
    field :app_version, :string
    field :platform, :string
    field :reason, :string
    field :network, :string
    field :metadata, :map

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :user_id,
      :room_code,
      :kind,
      :elapsed_ms,
      :app_version,
      :platform,
      :reason,
      :network,
      :metadata
    ])
    |> validate_required([:user_id, :room_code, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(
      :reason,
      ~w(backgrounded network_lost heartbeat_timeout push_timeout unknown)
    )
    |> validate_inclusion(:network, ~w(wifi cellular none unknown))
    |> validate_number(:elapsed_ms, greater_than_or_equal_to: 0)
  end
end

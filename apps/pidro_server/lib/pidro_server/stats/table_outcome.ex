defmodule PidroServer.Stats.TableOutcome do
  @moduledoc "One finalized human table's turn counts and first-takeover outcome; no move log."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "connection_table_outcomes" do
    field :game_instance_id, :string
    field :turns, :integer
    field :bot_turns, :integer
    field :others_finished, :boolean
    field :cohorts, {:array, :map}
    timestamps()
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :game_instance_id,
      :turns,
      :bot_turns,
      :others_finished,
      :cohorts,
      :inserted_at
    ])
    |> validate_required([:game_instance_id, :turns, :bot_turns, :cohorts])
    |> validate_number(:turns, greater_than_or_equal_to: 0)
    |> validate_number(:bot_turns, greater_than_or_equal_to: 0)
    |> unique_constraint(:game_instance_id)
  end

  @doc "Start a table aggregate, retaining original participants through departures."
  def new(seats),
    do: capture(%{turns: 0, bot_turns: 0, participants: %{}, peers: nil, left: []}, seats)

  @doc "Capture each human's latest client metadata, including temporarily covered seats."
  def capture(nil, _seats), do: nil

  def capture(outcome, seats) do
    clients =
      for {_position, seat} <- seats,
          id = human_id(seat),
          not is_nil(id),
          into: %{},
          do: {id, %{platform: seat.platform, app_version: seat.app_version}}

    %{outcome | participants: Map.merge(outcome.participants, clients)}
  end

  @doc "Count accepted bids/passes and card plays, not retries or administrative actions."
  def turn(nil, _seats, _action, _bot?), do: nil

  def turn(outcome, seats, action, bot?)
      when action == :pass or elem(action, 0) in [:bid, :play_card] do
    outcome = capture(outcome, seats)
    %{outcome | turns: outcome.turns + 1, bot_turns: outcome.bot_turns + if(bot?, do: 1, else: 0)}
  end

  def turn(outcome, _seats, _action, _bot?), do: outcome

  @doc "Freeze the other humans present at the first takeover. A solo table has no peers."
  def takeover(nil, _seats, _position), do: nil

  def takeover(%{peers: nil} = outcome, seats, position) do
    peers = for {pos, seat} <- seats, pos != position, id = human_id(seat), not is_nil(id), do: id
    %{capture(outcome, seats) | peers: peers}
  end

  def takeover(outcome, _seats, _position), do: outcome

  @doc "An intentional departure remains a departure even if the player later rejoins."
  def leave(nil, _id), do: nil
  def leave(outcome, id), do: %{outcome | left: Enum.uniq([id | outcome.left])}

  @doc "Reject partial accounting, including moves applied through administrative controls."
  def complete?(nil, _game), do: false

  def complete?(outcome, game) do
    outcome.turns ==
      Enum.count(game.events, fn
        {:bid_made, _, _} -> true
        {:player_passed, _} -> true
        {:card_played, _, _} -> true
        _ -> false
      end)
  end

  @doc "Finalize counts; no takeover or no other human means no completion-rate observation."
  def finish(nil, _seats, _completed?), do: nil

  def finish(outcome, seats, completed?) do
    outcome = capture(outcome, seats)

    present =
      for {_, seat} <- seats,
          seat.occupant_type == :human,
          seat.status == :connected,
          seat.background_token == nil,
          do: seat.user_id

    others_finished =
      if outcome.peers not in [nil, []] do
        completed? and Enum.all?(outcome.peers, &(&1 in present and &1 not in outcome.left))
      end

    %{
      turns: outcome.turns,
      bot_turns: outcome.bot_turns,
      others_finished: others_finished,
      cohorts: outcome.participants |> Map.values() |> Enum.uniq()
    }
  end

  defp human_id(%{occupant_type: :human, user_id: id}), do: id
  defp human_id(seat), do: seat.reserved_for
end

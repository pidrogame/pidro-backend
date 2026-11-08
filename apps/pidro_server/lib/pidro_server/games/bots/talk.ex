defmodule PidroServer.Games.Bots.Talk do
  @moduledoc """
  What a bot says at the table (PID-408): a line id or a coin, sent on the
  table's `"talk"` event like a person's word, rendered by the app as
  `talk.line_<voice>_<moment>_<n>`.

  A moment is something the table just saw. `moments/3` reads them from the
  engine's events, `replies/3` from a person's word; each comes as a group of
  `{moment, position, concerns?}` and `remark/2` lets at most one bot answer
  a group: the seat it concerns, else the chattier one. A character never
  repeats an item within a game nor within its last twelve, and two bots never
  send the same item within a hand. The memory lives in the room's `bot_talk`,
  so it follows a table through its rematches; an item counts as said once
  scheduled, even if the table moves on before it lands.
  """

  alias PidroServer.BotCatalogue
  alias PidroServer.Games.Room.Positions
  alias Pidro.Core.{Card, Types}

  @seats [:north, :east, :south, :west]

  # Five lines per voice for a moment at the table, three for a reply.
  @replies ~w(reply_hello reply_thanks reply_sorry reply_game)
  @moments ~w(hello bold_bid partner_points five_caught five_lost we_made we_set they_set
              game_won game_lost) ++ @replies

  # The coins a voice may send, after its lines.
  @coins %{
    {"partner_points", "cheerful"} => "coin_thumb",
    {"partner_points", "warm"} => "coin_heart",
    {"five_caught", "teasing"} => "coin_ha",
    {"five_lost", "cheerful"} => "coin_oops",
    {"they_set", "teasing"} => "coin_ha",
    {"game_won", "warm"} => "coin_heart"
  }

  @chances %{"sparse" => 0.15, "normal" => 0.35, "chatty" => 0.6}
  @chattiness %{"chatty" => 0, "normal" => 1, "sparse" => 2}

  @doc "The lines and coins `voice` may send for `moment`."
  @spec pool(String.t(), String.t()) :: [String.t()]
  def pool(moment, voice) when moment in @moments do
    count = if moment in @replies, do: 3, else: 5
    lines = for n <- 1..count, do: "line_#{voice}_#{moment}_#{n}"
    lines ++ List.wrap(@coins[{moment, voice}])
  end

  @doc """
  What `profile` says to `moment` at `room`, `{item, delay_ms}`, or nil: by
  its appetite's chance, from its voice's pool less what it said lately and
  what the table said this hand, after a beat on its tempo.
  """
  @spec pick(String.t(), map(), map(), boolean()) :: {String.t(), pos_integer()} | nil
  def pick(moment, %{bot_talk: talk}, profile, concerns? \\ false) do
    said = for {persona, item} <- talk.said, persona == profile.id, do: item

    with true <- :rand.uniform() < chance(moment, profile.appetite, concerns?),
         [_ | _] = pool <- pool(moment, profile.voice) -- (said ++ talk.hand) do
      factor = BotCatalogue.tempo_factor(profile.id)
      {Enum.random(pool), round((800 + :rand.uniform(1_700)) * factor)}
    else
      _ -> nil
    end
  end

  defp chance("reply_" <> _, _appetite, true), do: 0.8
  defp chance("reply_" <> _, _appetite, false), do: 0.3

  defp chance(moment, appetite, _concerns?) when moment in ~w(hello game_won game_lost),
    do: if(appetite == "sparse", do: 0.5, else: 1.0)

  defp chance(_moment, appetite, _concerns?), do: Map.get(@chances, appetite, 0.35)

  @doc """
  The first bot remark in `groups`, `{position, persona, item, delay_ms}`, or nil.
  """
  @spec remark([[{String.t(), Positions.position(), boolean()}]], map()) ::
          {Positions.position(), String.t(), String.t(), pos_integer()} | nil
  def remark(groups, room) do
    Enum.find_value(groups, fn group ->
      group
      |> Enum.flat_map(fn {moment, position, concerns?} ->
        case room.seats[position] do
          %{occupant_type: :bot, bot_persona: persona} when is_binary(persona) ->
            [{moment, position, concerns?, BotCatalogue.profile(persona)}]

          _ ->
            []
        end
      end)
      |> Enum.reject(&is_nil(elem(&1, 3)))
      |> Enum.sort_by(fn {_, _, concerns?, profile} ->
        {not concerns?, Map.get(@chattiness, profile.appetite, 1)}
      end)
      |> Enum.find_value(fn {moment, position, concerns?, profile} ->
        with {item, delay} <- pick(moment, room, profile, concerns?),
             do: {position, profile.id, item, delay}
      end)
    end)
  end

  @doc "Keeps what `persona` said in the room's memory."
  @spec remember(map(), String.t(), String.t()) :: map()
  def remember(talk, persona, item),
    do: %{talk | said: [{persona, item} | talk.said], hand: [item | talk.hand]}

  @doc "A new game: each character keeps only its last twelve."
  @spec new_game(map()) :: map()
  def new_game(talk) do
    {said, _} =
      Enum.flat_map_reduce(talk.said, %{}, fn {persona, _} = line, counts ->
        count = Map.get(counts, persona, 0)
        {if(count < 12, do: [line], else: []), Map.put(counts, persona, count + 1)}
      end)

    %{talk | said: said, hand: []}
  end

  @doc """
  The moments in the game's events after the first `seen`, the latest first,
  so a game's end outranks its last hand and a hand its last trick.
  """
  @spec moments([tuple()], non_neg_integer(), map()) :: [[tuple()]]
  def moments(events, seen, game_state) do
    {_table, groups} =
      events
      |> Enum.with_index()
      |> Enum.reduce({%{trump: nil, plays: [], bid: nil}, []}, fn {event, index},
                                                                  {table, groups} ->
        group = if index >= seen, do: moment(event, table, game_state), else: []
        {follow(event, table), if(group == [], do: groups, else: [group | groups])}
      end)

    groups
  end

  defp follow({:trump_declared, suit}, table), do: %{table | trump: suit}
  defp follow({:bidding_complete, position, bid}, table), do: %{table | bid: {position, bid}}

  defp follow({:card_played, position, card}, table),
    do: %{table | plays: [{position, card} | table.plays]}

  defp follow({:trick_won, _winner, _points}, table), do: %{table | plays: []}
  defp follow(_event, table), do: table

  defp moment({:dealer_selected, _position, _card}, _table, _game),
    do: for(position <- @seats, do: {"hello", position, false})

  defp moment({:trump_declared, _suit}, %{bid: {bidder, bid}}, _game) when bid >= 9,
    do: for(position <- side(opponent(bidder)), do: {"bold_bid", position, false})

  defp moment({:trick_won, winner, points}, table, _game) do
    fives =
      for {player, card} <- table.plays,
          Card.point_value(card, table.trump) == 5,
          team(player) != team(winner) do
        [{"five_caught", winner, true}, {"five_caught", Positions.partner(winner), false}] ++
          [{"five_lost", player, true}, {"five_lost", Positions.partner(player), false}]
      end

    partner = if points > 0, do: [{"partner_points", Positions.partner(winner), true}], else: []
    List.flatten(fives) ++ partner
  end

  defp moment({:hand_scored, team, _delta}, _table, %{
         last_hand: %{bidding_team: team, made: made}
       }) do
    [bidder | _] = Types.team_to_positions(team)

    if made do
      for position <- side(bidder), do: {"we_made", position, false}
    else
      for(position <- side(bidder), do: {"we_set", position, false}) ++
        for position <- side(opponent(bidder)), do: {"they_set", position, false}
    end
  end

  defp moment({:game_won, team, _score}, _table, _game) do
    for position <- @seats,
        do: {if(team(position) == team, do: "game_won", else: "game_lost"), position, false}
  end

  defp moment(_event, _table, _game), do: []

  @doc """
  Who may answer a person's `item` from `seat`: one bot for hello, good luck
  or good game; the bot that took the last trick for nice trick or well
  played, the bidder for good bid; the partner for sorry. Nothing else.
  """
  @spec replies(String.t(), Positions.position(), map() | nil) :: [[tuple()]]
  def replies(item, seat, game_state) do
    case {item, game_state} do
      {item, _} when item in ~w(word_hello word_luck) -> [anyone("reply_hello")]
      {"word_game", _} -> [anyone("reply_game")]
      {"word_sorry", _} -> [[{"reply_sorry", Positions.partner(seat), true}]]
      {item, game} when item in ~w(word_nice word_well) -> thanks(last_winner(game), seat)
      {"word_bid", game} -> thanks(bidder(game), seat)
      _ -> []
    end
  end

  defp anyone(moment), do: for(position <- @seats, do: {moment, position, false})

  defp thanks(position, seat) when position in @seats and position != seat,
    do: [[{"reply_thanks", position, true}]]

  defp thanks(_position, _seat), do: []

  defp last_winner(%{tricks: [_ | _] = tricks}), do: List.last(tricks).winner
  defp last_winner(%{last_hand: %{tricks: [_ | _] = tricks}}), do: List.last(tricks).winner
  defp last_winner(_game), do: nil

  defp bidder(%{highest_bid: {position, _bid}}), do: position
  defp bidder(%{last_hand: %{bidder: position}}), do: position
  defp bidder(_game), do: nil

  defp side(position), do: [position, Positions.partner(position)]

  defp opponent(position),
    do: Enum.at(@seats, rem(Enum.find_index(@seats, &(&1 == position)) + 1, 4))

  defp team(position), do: Types.position_to_team(position)
end

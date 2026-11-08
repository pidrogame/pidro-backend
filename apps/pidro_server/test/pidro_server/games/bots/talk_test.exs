defmodule PidroServer.Games.Bots.TalkTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.BotCatalogue
  alias PidroServer.BotCatalogue.Profile
  alias PidroServer.Games.Bots.Talk
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Games.RoomManager.Room

  setup do
    original = BotCatalogue.profiles()
    BotCatalogue.refresh()
    on_exit(fn -> :persistent_term.put(BotCatalogue, original) end)
    :rand.seed(:exsss, {408, 2026, 11})
    :ok
  end

  defp room(seats \\ %{}, talk \\ %{}) do
    seats =
      Map.new([:north, :east, :south, :west], fn position ->
        case seats[position] do
          nil -> {position, Seat.new_human(position, "person-#{position}")}
          persona -> {position, Seat.new_bot(position, nil, persona)}
        end
      end)

    %Room{seats: seats, bot_talk: Map.merge(%Room{}.bot_talk, talk)}
  end

  defp character(id, voice, appetite), do: %Profile{id: id, voice: voice, appetite: appetite}

  # How often `profile` speaks to `moment` with nothing said yet, over `n` draws.
  defp rate(moment, profile, n \\ 4_000) do
    hits = Enum.count(1..n, fn _ -> Talk.pick(moment, room(), profile) end)
    hits / n
  end

  describe "pick" do
    test "draws from the character's own voice: lines first, then that voice's coins" do
      antti = BotCatalogue.profile("antti")
      assert {antti.voice, antti.appetite} == {"teasing", "chatty"}

      drawn =
        for _ <- 1..400,
            {item, _delay} <- [Talk.pick("five_caught", room(), antti)],
            uniq: true,
            do: item

      assert Enum.sort(drawn) ==
               Enum.sort(~w(line_teasing_five_caught_1 line_teasing_five_caught_2
                    line_teasing_five_caught_3 line_teasing_five_caught_4
                    line_teasing_five_caught_5 coin_ha))

      assert Talk.pool("five_caught", "dry") ==
               for(n <- 1..5, do: "line_dry_five_caught_#{n}")

      assert Talk.pool("reply_sorry", "warm") ==
               for(n <- 1..3, do: "line_warm_reply_sorry_#{n}")

      assert Talk.pool("game_won", "warm") ==
               for(n <- 1..5, do: "line_warm_game_won_#{n}") ++ ["coin_heart"]
    end

    test "never repeats what the character said lately, nor what the table said this hand" do
      celeste = character("celeste", "teasing", "chatty")
      said = for n <- 1..4, do: {"celeste", "line_teasing_hello_#{n}"}

      for _ <- 1..50,
          do:
            assert(
              {"line_teasing_hello_5", _} = Talk.pick("hello", room(%{}, %{said: said}), celeste)
            )

      # Antti said the coin this hand: Celeste, the same voice, may not.
      hand = ["coin_ha" | for(n <- 1..4, do: "line_teasing_five_caught_#{n}")]

      picked =
        for _ <- 1..200,
            {item, _} <- [Talk.pick("five_caught", room(%{}, %{hand: hand}), celeste)],
            uniq: true,
            do: item

      assert picked == ["line_teasing_five_caught_5"]

      all = Talk.pool("hello", "teasing")
      assert Talk.pick("hello", room(%{}, %{hand: all}), celeste) == nil
    end

    test "a character says nothing twice in a game, and nothing of its last twelve in the next" do
      antti = BotCatalogue.profile("antti")
      moments = ~w(hello bold_bid partner_points five_caught five_lost we_made we_set they_set)

      talk =
        Enum.reduce(1..400, %Room{}.bot_talk, fn n, talk ->
          moment = Enum.at(moments, rem(n, length(moments)))

          case Talk.pick(moment, %Room{bot_talk: talk}, antti) do
            {item, _delay} -> Talk.remember(talk, "antti", item)
            nil -> talk
          end
        end)

      said = for {"antti", item} <- talk.said, do: item
      assert length(said) == length(Enum.uniq(said))
      # Every line of those eight moments once, and the coin once, though
      # two of them offer it.
      assert length(said) == 8 * 5 + 1
      assert Enum.count(said, &(&1 == "coin_ha")) == 1

      next = Talk.new_game(talk)
      assert next.said == Enum.take(talk.said, 12)
      assert next.hand == []

      again =
        for _ <- 1..300,
            {item, _} <- [Talk.pick("hello", %Room{bot_talk: next}, antti)],
            uniq: true,
            do: item

      kept = for {"antti", item} <- next.said, do: item
      assert again != []
      assert MapSet.disjoint?(MapSet.new(again), MapSet.new(kept))
    end

    test "appetite: sparse speaks under 0.2 of eligible moments, chatty over 0.5" do
      sparse = rate("partner_points", character("bengt", "dry", "sparse"))
      normal = rate("partner_points", character("jocke", "dry", "normal"))
      chatty = rate("partner_points", character("gun", "warm", "chatty"))

      assert sparse > 0.1 and sparse < 0.2
      assert normal > 0.3 and normal < 0.4
      assert chatty > 0.5 and chatty < 0.7

      # Hello and the game's end: always, or half the time for the sparse.
      assert rate("hello", character("gun", "warm", "chatty"), 200) == 1.0
      assert rate("game_lost", character("jocke", "dry", "normal"), 200) == 1.0
      sparse_end = rate("game_won", character("bengt", "dry", "sparse"))
      assert sparse_end > 0.45 and sparse_end < 0.55

      # A reply hangs on whom the word concerns, not on appetite.
      assert_in_delta rate_concerned(true), 0.8, 0.04
      assert_in_delta rate_concerned(false), 0.3, 0.04
    end

    test "the beat is 0.8 to 2.5 s, scaled by the character's tempo" do
      delays = fn id ->
        for _ <- 1..500,
            {_, delay} <- [Talk.pick("hello", room(), BotCatalogue.profile(id))],
            do: delay
      end

      # Marcel is quick (0.75), Jocke steady, Antti slow (1.3).
      quick = delays.("marcel")
      steady = delays.("jocke")
      slow = delays.("antti")

      assert Enum.min(steady) >= 800 and Enum.max(steady) <= 2_500
      assert Enum.min(quick) >= 600 and Enum.max(quick) <= 1_875
      assert Enum.min(slow) >= 1_040 and Enum.max(slow) <= 3_250
      assert Enum.max(quick) > 1_700 and Enum.min(slow) < 1_200
      mean = &(Enum.sum(&1) / length(&1))
      assert_in_delta mean.(slow) / mean.(quick), 1.3 / 0.75, 0.1
    end
  end

  defp rate_concerned(concerns?) do
    bengt = character("bengt", "dry", "sparse")
    Enum.count(1..2_000, fn _ -> Talk.pick("reply_thanks", room(), bengt, concerns?) end) / 2_000
  end

  describe "moments" do
    # North bids 10 in hearts. East throws the Wrong Five (diamonds) under
    # North's ace: the Five is caught by North-South, lost by East-West.
    @events [
      {:dealer_selected, :north, {14, :spades}},
      {:cards_dealt, %{}},
      {:bid_made, :north, 10},
      {:bidding_complete, :north, 10},
      {:trump_declared, :hearts},
      {:card_played, :north, {14, :hearts}},
      {:card_played, :east, {5, :diamonds}},
      {:card_played, :south, {3, :hearts}},
      {:card_played, :west, {4, :hearts}},
      {:trick_won, :north, 6},
      # West keeps its own Five: points for East-West, no Five moment.
      {:card_played, :west, {5, :hearts}},
      {:card_played, :north, {2, :hearts}},
      {:card_played, :east, {6, :hearts}},
      {:card_played, :south, {7, :hearts}},
      {:trick_won, :east, 6}
    ]

    test "read from the engine's events, latest first, only past what was already seen" do
      assert Talk.moments(@events, 0, %{}) == [
               [{"partner_points", :west, true}],
               [
                 {"five_caught", :north, true},
                 {"five_caught", :south, false},
                 {"five_lost", :east, true},
                 {"five_lost", :west, false},
                 {"partner_points", :south, true}
               ],
               [{"bold_bid", :east, false}, {"bold_bid", :west, false}],
               for(seat <- [:north, :east, :south, :west], do: {"hello", seat, false})
             ]

      assert Talk.moments(@events, 10, %{}) == [[{"partner_points", :west, true}]]
      assert Talk.moments(@events, length(@events), %{}) == []

      # Eight is not bold.
      events = List.replace_at(@events, 3, {:bidding_complete, :north, 8})
      refute Enum.any?(Talk.moments(events, 0, %{}), &match?([{"bold_bid", _, _} | _], &1))
    end

    test "the hand's result from the engine's last hand, and the game's end" do
      scored = [{:hand_scored, :north_south, -10}, {:hand_scored, :east_west, 6}]
      set = %{last_hand: %{bidding_team: :north_south, made: false}}

      assert Talk.moments(@events ++ scored, length(@events), set) == [
               [
                 {"we_set", :north, false},
                 {"we_set", :south, false},
                 {"they_set", :east, false},
                 {"they_set", :west, false}
               ]
             ]

      made = [{:hand_scored, :east_west, 7}, {:hand_scored, :north_south, 3}]

      assert Talk.moments(made, 0, %{last_hand: %{bidding_team: :east_west, made: true}}) ==
               [[{"we_made", :east, false}, {"we_made", :west, false}]]

      assert [[{"game_won", :north, false}, {"game_lost", :east, false} | _] | _] =
               Talk.moments(made ++ [{:game_won, :north_south, 63}], 0, %{
                 last_hand: %{bidding_team: :east_west, made: true}
               })
    end
  end

  describe "remark" do
    test "one bot answers: the seat the moment concerns first, else the chattier" do
      # Bengt (sparse) at west, Gun (chatty) at east, Antti (chatty) at south.
      seats = %{west: "bengt", east: "gun", south: "antti"}

      for {id, voice, appetite} <- [{"bengt", "dry", "sparse"}, {"gun", "warm", "chatty"}],
          do:
            {:ok, _} =
              BotCatalogue.save(%Profile{id: id}, %{
                name: String.capitalize(id),
                voice: voice,
                appetite: appetite
              })

      room = room(seats)

      # Hello: chatty bots always speak, so the chattier seat wins; the seat
      # order breaks the tie between Gun and Antti.
      for _ <- 1..50 do
        assert {:east, "gun", "line_warm_hello_" <> _, _} =
                 Talk.remark(
                   [for(s <- [:north, :east, :south, :west], do: {"hello", s, false})],
                   room
                 )
      end

      # Bengt is the one it concerns: he goes first, half the time he speaks.
      speakers =
        for _ <- 1..400 do
          {position, _, _, _} =
            Talk.remark([[{"hello", :east, false}, {"hello", :west, true}]], room)

          position
        end

      assert_in_delta Enum.count(speakers, &(&1 == :west)) / 400, 0.5, 0.08
      assert Enum.uniq(speakers) |> Enum.sort() == [:east, :west]

      # A human seat never speaks, and a later group only if the first is silent.
      assert Talk.remark([[{"hello", :north, true}]], room) == nil
      assert {:east, _, _, _} = Talk.remark([[], [{"hello", :east, false}]], room)
    end

    test "replies: one bot for hello and good game, the bot it concerns for thanks and sorry" do
      game = %{tricks: [%{winner: :west}], highest_bid: {:east, 9}}

      assert Talk.replies("word_hello", :north, nil) ==
               [for(s <- [:north, :east, :south, :west], do: {"reply_hello", s, false})]

      assert Talk.replies("word_luck", :north, nil) == Talk.replies("word_hello", :north, nil)
      assert [[{"reply_game", _, false} | _]] = Talk.replies("word_game", :north, nil)
      assert Talk.replies("word_nice", :north, game) == [[{"reply_thanks", :west, true}]]
      assert Talk.replies("word_well", :north, game) == [[{"reply_thanks", :west, true}]]
      assert Talk.replies("word_bid", :north, game) == [[{"reply_thanks", :east, true}]]
      assert Talk.replies("word_nice", :west, game) == []
      assert Talk.replies("word_sorry", :north, game) == [[{"reply_sorry", :south, true}]]
      assert Talk.replies("word_nice", :north, nil) == []

      for item <- ~w(word_thanks word_oops word_noworries coin_heart coin_ha),
          do: assert(Talk.replies(item, :north, game) == [])
    end
  end
end

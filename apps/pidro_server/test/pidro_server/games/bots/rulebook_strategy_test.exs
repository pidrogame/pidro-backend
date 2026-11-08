defmodule PidroServer.Games.Bots.RulebookStrategyTest do
  @moduledoc """
  Seated bots decide through the engine rulebook from a seat view only.
  """

  use PidroServer.DataCase, async: false

  import ExUnit.CaptureLog

  alias Pidro.Core.SeatView
  alias PidroServer.Games.Bots.{BotBrain, BotManager}
  alias PidroServer.Games.Bots.Strategies.{RulebookStrategy, SearchStrategy}
  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomManager}

  defmodule RecordingStrategy do
    @moduledoc false
    @behaviour PidroServer.Games.Bots.Strategy

    @impl true
    def pick_action(legal_actions, view) do
      send(self(), {:picked, legal_actions, view})
      RulebookStrategy.pick_action(legal_actions, view)
    end
  end

  defmodule RaisingStrategy do
    @moduledoc false
    @behaviour PidroServer.Games.Bots.Strategy

    @impl true
    def pick_action(_legal_actions, _view), do: raise("strategy exploded")
  end

  defmodule IllegalStrategy do
    @moduledoc false
    @behaviour PidroServer.Games.Bots.Strategy

    @impl true
    def pick_action(_legal_actions, _view), do: {:ok, {:bid, 99}, "an impossible bid"}
  end

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    for supervisor <- [PidroServer.Games.Bots.BotSupervisor, BotManager] do
      if GenServer.whereis(supervisor) == nil, do: start_supervised!(supervisor)
    end

    # Human seats must not be auto-played by the turn timer mid-test.
    original = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(original, turn_timer_bid_ms: 60_000, turn_timer_play_ms: 60_000)
    )

    on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
    :ok
  end

  # Four humans at the table, bidding under way.
  defp bidding_room do
    {:ok, room} = RoomManager.create_room("rb_user1", %{name: "Rulebook"})

    for user <- ["rb_user2", "rb_user3", "rb_user4"],
        do: {:ok, _, _} = RoomManager.join_room(room.code, user)

    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, game} = GameAdapter.get_state(room.code)

    if game.phase == :dealer_selection,
      do: {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)

    {:ok, %{phase: :bidding} = game} = wait_for_phase(room.code, :bidding)
    {room, game}
  end

  defp wait_for_phase(room_code, phase, attempts \\ 200) do
    case GameAdapter.get_state(room_code) do
      {:ok, %{phase: ^phase}} = ok ->
        ok

      _ when attempts > 0 ->
        Process.sleep(5)
        wait_for_phase(room_code, phase, attempts - 1)

      other ->
        other
    end
  end

  describe "pick_action/2" do
    test "every legacy difficulty uses public history to recognise the spent Ace" do
      {_room, game} = bidding_room()

      view = %{
        SeatView.for_seat(game, :south)
        | phase: :playing,
          trump_suit: :hearts,
          hand: [{5, :hearts}, {9, :hearts}, {3, :hearts}],
          current_trick: %Pidro.Core.Types.Trick{
            number: 2,
            leader: :north,
            plays: [north: {13, :hearts}, east: {7, :hearts}]
          },
          tricks: [
            %Pidro.Core.Types.Trick{
              number: 1,
              leader: :north,
              plays: [
                north: {14, :hearts},
                east: {4, :hearts},
                south: {2, :hearts},
                west: {6, :hearts}
              ]
            }
          ]
      }

      legal = Enum.map(view.hand, &{:play_card, &1})
      assert {:ok, {:play_card, {5, :hearts}}, _} = RulebookStrategy.pick_action(legal, view)

      for difficulty <- [:random, :basic, :smart] do
        strategy = PidroServer.Games.Bots.Strategy.resolve(difficulty)
        assert {:ok, {:play_card, {5, :hearts}}, _} = strategy.pick_action(legal, view)
      end
    end

    test "returns a legal action and a one-sentence reason from the seat view" do
      {_room, game} = bidding_room()
      view = SeatView.for_seat(game, game.current_turn)
      legal = Pidro.Game.Engine.legal_actions(game, game.current_turn)

      assert {:ok, action, reason} = RulebookStrategy.pick_action(legal, view)
      assert action in legal
      assert reason =~ ~r/^[A-Z][^.]*\.$/
    end
  end

  # A legacy strategy name selects nothing: the seat's character decides, and
  # the seeded crew plays search (PID-403).
  describe "strategy names" do
    for {name, strategy} <- [
          random: SearchStrategy,
          basic: SearchStrategy,
          smart: SearchStrategy
        ] do
      test "#{name} starts a bot that plays its character's strategy" do
        {:ok, room} = RoomManager.create_room("host_user", %{})
        {:ok, pid} = BotManager.start_bot(room.code, :east, unquote(name), 0)

        assert :sys.get_state(pid).strategy == unquote(strategy)
        BotManager.stop_all_bots(room.code)
      end
    end
  end

  describe "BotBrain.execute_move/3" do
    test "a selected move cannot apply after the turn changes even when it remains legal" do
      {room, game} = bidding_room()
      {:ok, pid} = PidroServer.Games.GameRegistry.lookup(room.code)
      newer = %{game | events: game.events ++ [{:cards_dealt, %{}}]}

      capture_log(fn ->
        BotBrain.execute_move(
          %{room_code: room.code, position: game.current_turn, strategy: RulebookStrategy},
          "Test",
          fn code, position, action, turn ->
            :ok = GenServer.call(pid, {:set_state, newer})
            assert action in Pidro.Game.Engine.legal_actions(newer, position)

            result =
              GameAdapter.apply_action(code, position, action, 5_000, %{expected_turn: turn})

            assert {:error, :stale_turn} = result
            result
          end
        )
      end)

      assert {:ok, ^newer} = GameAdapter.get_state(room.code)
    end

    test "hands the strategy a seat view with only counts for the other hands" do
      {room, game} = bidding_room()
      position = game.current_turn

      :ok =
        BotBrain.execute_move(
          %{room_code: room.code, position: position, strategy: RecordingStrategy},
          "Test"
        )

      assert_received {:picked, legal, %SeatView{position: ^position} = view}
      assert legal != []
      assert view.hand == game.players[position].hand
      refute Map.has_key?(view, :events)
      refute Map.has_key?(view, :deck)

      for {pos, player} <- view.players, pos != position do
        refute Map.has_key?(player, :hand)
        assert player.hand_count == 9
      end

      {:ok, after_move} = GameAdapter.get_state(room.code)
      assert length(after_move.bids) == length(game.bids) + 1
    end

    test "a strategy that raises does not stop the turn" do
      {room, game} = bidding_room()

      log =
        capture_log(fn ->
          assert :ok =
                   BotBrain.execute_move(
                     %{
                       room_code: room.code,
                       position: game.current_turn,
                       strategy: RaisingStrategy
                     },
                     "Test"
                   )
        end)

      assert log =~ "strategy exploded"
      {:ok, after_move} = GameAdapter.get_state(room.code)
      assert length(after_move.bids) == length(game.bids) + 1
    end

    test "an illegal choice falls back to a legal move" do
      {room, game} = bidding_room()

      log =
        capture_log(fn ->
          BotBrain.execute_move(
            %{room_code: room.code, position: game.current_turn, strategy: IllegalStrategy},
            "Test"
          )
        end)

      assert log =~ "not legal"
      {:ok, after_move} = GameAdapter.get_state(room.code)
      assert [_ | _] = after_move.bids -- game.bids
    end

    test "resolves the manual-rob marker into a concrete six-card selection" do
      {room, game} = bidding_room()
      dealer = game.current_dealer
      trump = :hearts
      deck = [{14, :hearts}, {13, :hearts}, {3, :spades}, {9, :hearts}]
      hand = [{5, :hearts}, {2, :hearts}, {4, :hearts}]

      rob_state = %{
        game
        | phase: :second_deal,
          current_turn: dealer,
          trump_suit: trump,
          highest_bid: {Pidro.Core.Types.next_position(dealer), 7},
          bidding_team: Pidro.Core.Types.position_to_team(Pidro.Core.Types.next_position(dealer)),
          deck: deck,
          config: Map.put(game.config, :auto_dealer_rob, false),
          players: Map.update!(game.players, dealer, &%{&1 | hand: hand})
      }

      {:ok, pid} = PidroServer.Games.GameRegistry.lookup(room.code)
      :ok = GenServer.call(pid, {:set_state, rob_state})

      assert {:ok, [{:select_hand, :choose_6_cards}]} =
               GameAdapter.get_legal_actions(room.code, dealer)

      :ok =
        BotBrain.execute_move(
          %{room_code: room.code, position: dealer, strategy: RulebookStrategy},
          "Test"
        )

      {:ok, robbed} = GameAdapter.get_state(room.code)
      assert robbed.phase == :playing
      kept = robbed.players[dealer].hand
      assert length(kept) == 6
      assert Enum.all?(kept, &(&1 in (hand ++ deck)))
    end
  end
end

defmodule PidroServer.Games.GameTopicContractTest do
  use PidroServerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest, only: [subscribe_and_join: 4, assert_push: 2]
  require Phoenix.ChannelTest

  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServer.Games.Bots.{BotPlayer, SubstituteBot}
  alias PidroServerWeb.{GameChannel, UserSocket}
  alias PidroServerWeb.Dev.GameDetailLive

  @event [:pidro_server, :game_topic, :unexpected_message]
  @subscribers [BotPlayer, SubstituteBot, RoomManager, GameChannel, GameDetailLive]

  setup :register_and_log_in_admin

  setup %{conn: conn} do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    host = PidroServer.AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Topic contract"})
    {:ok, view, _html} = live(conn, ~p"/admin/games/#{room.code}")

    bot = start_supervised!({BotPlayer, room_code: room.code, position: :east, paused?: true})
    substitute = start_supervised!({SubstituteBot, room_code: room.code, position: :west})
    token = PidroServer.Accounts.Token.generate(host)
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}", %{})

    subscribers = %{
      BotPlayer => bot,
      SubstituteBot => substitute,
      RoomManager => Process.whereis(RoomManager),
      GameChannel => socket.channel_pid,
      GameDetailLive => view.pid
    }

    Enum.each(subscribers, fn {_, pid} -> :sys.get_state(pid) end)
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @event, &__MODULE__.record_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, readiness} = RoomManager.readiness(room.code)
    {:ok, lifecycle} = RoomManager.get_seat_lifecycle(room.code)

    %{
      subscribers: subscribers,
      messages: messages(room.code, host.id, readiness, lifecycle),
      room: room,
      view: view
    }
  end

  def record_event(_event, measurements, metadata, pid) do
    send(pid, {:unexpected, measurements, metadata})
  end

  for subscriber <- @subscribers do
    test "#{inspect(subscriber)} handles the published vocabulary without fallback", context do
      pid = context.subscribers[unquote(subscriber)]

      log =
        capture_log(fn ->
          for message <- context.messages do
            send(pid, message)
            :sys.get_state(pid)
            assert Process.alive?(pid)
          end
        end)

      refute log =~ "ignored unexpected message"
      refute_received {:unexpected, _, _}

      if unquote(subscriber) == GameChannel do
        assert_push "game_state", %{state: %{phase: :complete}}
        assert_push "game_over", %{winner: :east_west, scores: %{east_west: 64, north_south: 42}}
        assert_push "progression_summary", %{xp: 17}
        assert_push "player_kicked", %{position: :south}
        assert_push "seat_invitation_declined", %{position: :south, reason: "not_now"}
      end
    end
  end

  test "unknown envelopes preserve each subscriber's state and report no payload", context do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    for {subscriber, pid} <- context.subscribers,
        {message, tag, arity} <- [
          {{:future_event, %{private: "do-not-log-this"}}, :future_event, 2},
          {{:seat_lifecycle, %{}, :new_shape}, :seat_lifecycle, 3},
          {:future_signal, :future_signal, 0},
          {%{private: "do-not-log-this"}, :untagged, 0}
        ] do
      before = :sys.get_state(pid)

      log =
        capture_log([level: :debug], fn ->
          send(pid, message)
          assert :sys.get_state(pid) == before
        end)

      assert log =~ inspect(subscriber)
      assert log =~ "tag=#{inspect(tag)} arity=#{arity}"
      refute log =~ "do-not-log-this"

      assert_received {:unexpected, %{count: 1},
                       %{subscriber: ^subscriber, tag: ^tag, arity: ^arity}}

      refute_received {:unexpected, _, _}
    end
  end

  test "real room joins and channel broadcasts keep the admin view alive", context do
    guest = PidroServer.AccountsFixtures.user_fixture()
    assert {:ok, _, _} = RoomManager.join_room(context.room.code, guest.id)
    assert render(context.view) =~ "3 / 4"

    GameAdapter.subscribe(context.room.code)
    PidroServerWeb.Endpoint.broadcast("game:#{context.room.code}", "presence_diff", %{})
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
    assert has_element?(context.view, "dd", "3 / 4")
    refute_received {:unexpected, _, _}

    assert :ok = RoomManager.close_room(context.room.code)
    assert_redirect context.view, "/admin/games"
  end

  test "every raw game-topic publication has an exercised tag and arity", context do
    published =
      Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__))
      |> Enum.flat_map(fn path ->
        ast = path |> File.read!() |> Code.string_to_quoted!()

        {_, signatures} =
          Macro.prewalk(ast, [], fn
            {:defp, _, [{:broadcast_game_event, _, _}, [do: body]]}, acc ->
              # Inventory the wrapper at its call sites, not its definition.
              assert match?(
                       {{:., _, [{:__aliases__, _, [:Phoenix, :PubSub]}, :broadcast_from]}, _,
                        [_, _, {:<<>>, _, ["game:" | _]}, {:event, _, nil}]},
                       body
                     )

              {nil, acc}

            {:broadcast_game_event, _, [_room, event]} = node, acc ->
              {node, [signature(event) | acc]}

            {{:., _, [{:__aliases__, _, [:Phoenix, :PubSub]}, function]}, _, args} = node, acc
            when function in [:broadcast, :broadcast_from] ->
              [topic, event] = Enum.take(args, -2)

              case topic do
                {:<<>>, _, ["game:" | _]} ->
                  {node, [signature(event) | acc]}

                _ ->
                  {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        signatures
      end)
      |> MapSet.new()

    exercised = MapSet.new(context.messages, &{elem(&1, 0), tuple_size(&1)})
    assert published == exercised
  end

  defp signature({:{}, _, [tag | rest]}) when is_atom(tag), do: {tag, length(rest) + 1}
  defp signature({tag, _payload}) when is_atom(tag), do: {tag, 2}
  defp signature(ast), do: flunk("Unrecognised game event publication: #{Macro.to_string(ast)}")

  # One vocabulary of raw application messages. Phoenix broadcast structs use
  # the channel's handle_out path and are covered by the integration test above.
  defp messages(code, user_id, readiness, lifecycle) do
    state = %{Pidro.Core.GameState.new(seed: 1) | phase: :complete}

    [
      {:state_update, code, %{state: state, transition_delay_ms: 0}},
      {:game_over, code, :east_west, %{east_west: 64, north_south: 42}},
      {:progression_summary, code, %{user_id => %{xp: 17}, "opponent" => %{xp: 99}}},
      {:turn_timer_started, %{timer_id: "timer-1"}},
      {:turn_timer_cancelled, %{timer_id: "timer-1"}},
      {:turn_auto_played, %{position: :south}},
      {:player_reconnecting, %{position: :south, user_id: "other"}},
      {:player_reconnected, %{position: :south, user_id: "other"}},
      {:player_reclaimed_seat, %{position: :south, user_id: "other"}},
      {:bot_substitute_active, %{position: :south, user_id: "other"}},
      {:seat_permanently_botted, %{position: :south}},
      {:owner_decision_available, %{position: :south, owner_id: user_id}},
      {:owner_changed, %{new_owner_id: user_id, new_owner_position: :north}},
      {:substitute_available, %{position: :south}},
      {:substitute_seat_closed, %{position: :south}},
      {:substitute_joined, %{position: :south, user_id: "other"}},
      {:seat_lifecycle, lifecycle},
      {:readiness_updated, readiness},
      {:invite_redeemed,
       %{position: :south, user_id: "other", username: "guest", display_name: "Guest"}},
      {:seat_moved, %{user_id: "other", from: :south, to: :west}},
      {:kicked, %{position: :south, user_id: "other"}},
      {:seat_invitation_declined, %{position: :south, user_id: user_id, reason: "not_now"}}
    ]
  end
end

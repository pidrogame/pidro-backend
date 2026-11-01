defmodule PidroServerWeb.TalkChannelTest do
  @moduledoc """
  Table talk on the game channel with one real socket per person: each client
  runs in its own process, so a push reaches exactly the client it was meant
  for and the test can say who received what.
  """

  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.AccountsFixtures
  alias PidroServer.Blocks
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServer.Repo
  alias PidroServerWeb.{GameChannel, UserSocket}

  @moduletag :channel

  setup do
    Process.flag(:trap_exit, true)
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    adult = adult()
    adult2 = adult()
    teen = AccountsFixtures.user_fixture() |> age("13_17")
    guest = AccountsFixtures.guest_fixture()
    watcher = adult()

    {:ok, room} = RoomManager.create_room(adult.id, %{name: "Talk"})
    for user <- [adult2, teen, guest], do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    {:ok, _} = Blocks.block(adult2.id, teen.id)
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, _} = RoomManager.join_spectator_room(room.code, watcher.id)

    people = %{adult: adult, adult2: adult2, teen: teen, guest: guest, watcher: watcher}
    clients = Map.new(people, fn {name, user} -> {name, client(name, user, room.code)} end)

    %{people: people, clients: clients, room: room}
  end

  describe "talk" do
    test "a face or a word reaches every socket but the blocked pair", ctx do
      %{adult: adult, adult2: adult2, teen: teen, guest: guest} = ctx.people
      everyone = Map.keys(ctx.clients)

      assert send_talk(ctx, :adult, %{"item" => "coin_heart"}) == :ok

      assert received(ctx) ==
               for(name <- everyone, into: %{}, do: {name, [talk(:north, adult, "coin_heart")]})

      assert send_talk(ctx, :adult2, %{"item" => "word_nice"}) == :ok

      assert received(ctx) ==
               for(
                 name <- everyone -- [:teen],
                 into: %{},
                 do: {name, [talk(:east, adult2, "word_nice")]}
               )

      assert send_talk(ctx, :teen, %{"item" => "word_thanks"}) == :ok

      assert received(ctx) ==
               for(
                 name <- everyone -- [:adult2],
                 into: %{},
                 do: {name, [talk(:south, teen, "word_thanks")]}
               )

      assert send_talk(ctx, :guest, %{"item" => "coin_ha"}) == :ok

      assert received(ctx) ==
               for(name <- everyone, into: %{}, do: {name, [talk(:west, guest, "coin_ha")]})
    end

    test "a block made at the table takes effect at once, and an unblock lifts it", ctx do
      {:ok, _} = Blocks.block(ctx.people.teen.id, ctx.people.adult.id)
      assert send_talk(ctx, :adult, %{"item" => "coin_heart"}) == :ok
      refute Map.has_key?(received(ctx), :teen)

      {:ok, _} = Blocks.unblock(ctx.people.teen.id, ctx.people.adult.id)
      assert send_talk(ctx, :adult, %{"item" => "coin_heart"}) == :ok
      assert Map.has_key?(received(ctx), :teen)
    end

    test "the server names the seat and sender; a spoofed one is ignored", ctx do
      spoof = %{"item" => "coin_wow", "seat" => "west", "user_id" => ctx.people.guest.id}
      assert send_talk(ctx, :adult, spoof) == :ok

      assert %{teen: [%{seat: :north, user_id: id, item: "coin_wow"} = payload]} = received(ctx)
      assert id == ctx.people.adult.id
      assert Map.keys(payload) |> Enum.sort() == [:item, :seat, :user_id]
    end

    test "a spectator and an unknown item are refused and reach nobody", ctx do
      assert send_talk(ctx, :watcher, %{"item" => "coin_heart"}) ==
               {:error, %{error: "not_seated"}}

      assert send_talk(ctx, :adult, %{"item" => "word_rude"}) ==
               {:error, %{error: "invalid_item"}}

      assert send_talk(ctx, :adult, %{"item" => 7}) == {:error, %{error: "invalid_item"}}
      assert send_talk(ctx, :adult, %{}) == {:error, %{error: "invalid_item"}}
      assert received(ctx) == %{}
    end

    test "five in ten seconds, then the sixth is refused", ctx do
      for _ <- 1..5, do: assert(send_talk(ctx, :guest, %{"item" => "coin_thumb"}) == :ok)

      assert send_talk(ctx, :guest, %{"item" => "coin_thumb"}) ==
               {:error, %{error: "rate_limited"}}

      assert ctx |> received() |> Map.fetch!(:adult) |> length() == 5
      assert send_talk(ctx, :adult, %{"item" => "coin_thumb"}) == :ok
    end
  end

  describe "moment" do
    test "start reaches the four seats, not the spectator, and bidding brings none", ctx do
      {:ok, _} = GameAdapter.apply_action(ctx.room.code, :north, :select_dealer)

      assert received(ctx, "moment") ==
               for(
                 name <- [:adult, :adult2, :teen, :guest],
                 into: %{},
                 do: {name, [%{id: "start"}]}
               )

      bid_out(ctx.room.code)
      assert received(ctx, "moment") == %{}
    end

    test "partner_trick reaches the partner of the winner; game_end everyone seated", ctx do
      {:ok, _} = GameAdapter.apply_action(ctx.room.code, :north, :select_dealer)
      _ = received(ctx, "moment")

      sent = broadcast_events(ctx.room.code, [{:trick_won, :east, 5}, {:trick_won, :north, 0}])
      assert received(ctx, "moment") == %{guest: [%{id: "partner_trick"}]}

      sent = broadcast_events(ctx.room.code, [{:trick_won, :south, 1}], sent)
      assert received(ctx, "moment") == %{adult: [%{id: "partner_trick"}]}

      broadcast_events(ctx.room.code, [{:game_won, :north_south, 62}], sent)

      assert received(ctx, "moment") ==
               for(
                 name <- [:adult, :adult2, :teen, :guest],
                 into: %{},
                 do: {name, [%{id: "game_end"}]}
               )
    end

    test "a seated player who joins again is not told what happened before", ctx do
      {:ok, _} = GameAdapter.apply_action(ctx.room.code, :north, :select_dealer)
      _ = received(ctx, "moment")

      ctx =
        put_in(ctx.clients[:adult_again], client(:adult_again, ctx.people.adult, ctx.room.code))

      assert received(ctx, "moment") == %{}

      broadcast_events(ctx.room.code, [{:trick_won, :south, 1}])

      assert received(ctx, "moment") ==
               %{adult: [%{id: "partner_trick"}], adult_again: [%{id: "partner_trick"}]}
    end
  end

  test "a bot partner gets nothing; a human partner of a bot does" do
    [north, east] = [adult(), adult()]
    {:ok, room} = RoomManager.create_room(north.id, %{name: "Two and two"})
    {:ok, _, _} = RoomManager.join_room(room.code, east.id)
    for pos <- [:south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)
    PidroServer.RoomFixtures.ready_room(room.code)

    ctx = %{
      clients: %{north: client(:north, north, room.code), east: client(:east, east, room.code)}
    }

    {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    assert received(ctx, "moment") == %{north: [%{id: "start"}], east: [%{id: "start"}]}

    sent = broadcast_events(room.code, [{:trick_won, :north, 5}])
    assert received(ctx, "moment") == %{}

    broadcast_events(room.code, [{:trick_won, :west, 5}], sent)
    assert received(ctx, "moment") == %{east: [%{id: "partner_trick"}]}
  end

  test "a table with one human and bots cannot talk" do
    player = adult()
    {:ok, room} = RoomManager.create_room(player.id, %{solo: true})
    for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)
    PidroServer.RoomFixtures.ready_room(room.code)
    ctx = %{clients: %{solo: client(:solo, player, room.code)}}

    assert send_talk(ctx, :solo, %{"item" => "word_hello"}) == {:error, %{error: "no_table"}}
    assert received(ctx) == %{}
  end

  # A client process owns its socket: pushes and replies go to it, and it
  # forwards them to the test tagged with its name.
  defp client(name, user, code) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} =
          connect(UserSocket, %{"token" => create_token(user)}, test_process: test)

        {:ok, _reply, channel} = join(socket, GameChannel, "game:#{code}")
        send(test, {:joined, name})
        relay(test, name, channel)
      end)

    assert_receive {:joined, ^name}, 2_000
    pid
  end

  defp relay(test, name, channel) do
    receive do
      {:push, event, payload} ->
        ref = push(channel, event, payload)
        send(test, {:pushed, name, ref})

      %Phoenix.Socket.Message{event: event, payload: payload} ->
        send(test, {:got, name, event, payload})

      %Phoenix.Socket.Reply{ref: ref, status: status, payload: payload} ->
        send(test, {:reply, name, ref, status, payload})

      _other ->
        :ok
    end

    relay(test, name, channel)
  end

  defp send_talk(ctx, name, payload), do: call(ctx, name, "talk", payload)

  defp call(ctx, name, event, payload) do
    send(ctx.clients[name], {:push, event, payload})
    assert_receive {:pushed, ^name, ref}

    case assert_receive({:reply, ^name, ^ref, _status, _reply}, 2_000) do
      {_, _, _, :ok, empty} when empty == %{} -> :ok
      {_, _, _, status, reply} -> {status, reply}
    end
  end

  # Every `event` push each client received, waiting briefly for stragglers.
  defp received(ctx, event \\ "talk", acc \\ %{}) do
    receive do
      {:got, name, ^event, payload} when is_map_key(ctx.clients, name) ->
        received(ctx, event, Map.update(acc, name, [payload], &(&1 ++ [payload])))
    after
      150 -> acc
    end
  end

  # The live game, or the last snapshot sent, with `events` appended, as the
  # game would broadcast it. Returns the snapshot so a test can send the next.
  defp broadcast_events(code, events, snapshot \\ nil) do
    snapshot = snapshot || elem(GameAdapter.get_snapshot(code), 1)
    state = %{snapshot.state | events: snapshot.state.events ++ events}
    revision = snapshot.state_revision + 1

    snapshot =
      Map.merge(snapshot, %{state: state, state_revision: revision, transition_delay_ms: 0})

    Phoenix.PubSub.broadcast(PidroServer.PubSub, "game:#{code}", {:state_update, code, snapshot})
    snapshot
  end

  defp wait_for_phase(code, phase, tries \\ 100) do
    {:ok, state} = GameAdapter.get_state(code)

    cond do
      state.phase == phase -> state
      tries == 0 -> flunk("game stayed in #{state.phase}")
      true -> Process.sleep(50) && wait_for_phase(code, phase, tries - 1)
    end
  end

  # Everyone passes or makes the lowest bid until bidding is over.
  defp bid_out(code) do
    state = wait_for_phase(code, :bidding)
    seat = state.current_turn
    actions = Pidro.Game.Engine.legal_actions(state, seat)
    action = if :pass in actions, do: :pass, else: Enum.min(actions)
    {:ok, next} = GameAdapter.apply_action(code, seat, action)
    if next.phase == :bidding, do: bid_out(code)
  end

  defp talk(seat, user, item), do: %{seat: seat, user_id: user.id, item: item}

  defp adult, do: AccountsFixtures.user_fixture() |> age("18_plus")

  defp age(user, band), do: user |> Ecto.Changeset.change(age_band: band) |> Repo.update!()
end

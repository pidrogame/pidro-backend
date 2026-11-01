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
  alias PidroServer.Games.RoomManager
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

  # Everything talk-shaped each client received, waiting briefly for stragglers.
  defp received(_ctx, acc \\ %{}) do
    receive do
      {:got, name, event, payload} when event == "talk" ->
        received(nil, Map.update(acc, name, [payload], &(&1 ++ [payload])))
    after
      150 -> acc
    end
  end

  defp talk(seat, user, item), do: %{seat: seat, user_id: user.id, item: item}

  defp adult, do: AccountsFixtures.user_fixture() |> age("18_plus")

  defp age(user, band), do: user |> Ecto.Changeset.change(age_band: band) |> Repo.update!()
end

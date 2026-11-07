defmodule PidroServer.BotCatalogueTest do
  use PidroServer.DataCase, async: false
  alias PidroServer.BotCatalogue
  alias PidroServer.BotCatalogue.Profile
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Games.{RoomManager, Bots.BotManager}
  alias PidroServer.Games.Bots.Strategies.{RandomStrategy, RulebookStrategy}

  setup do
    RoomManager.reset_for_test()
    BotCatalogue.refresh()

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      :persistent_term.put(BotCatalogue, BotCatalogue.defaults())
    end)

    :ok
  end

  test "four enabled bots fill four seats without duplication, even in a pre-existing room" do
    {:ok, room} = RoomManager.create_room("host", %{})
    {:ok, fourth} = BotCatalogue.save(BotCatalogue.new(), %{name: "Fourth", portrait: "antti"})
    # Use the same empty-table setup as the existing four-bot admin preset.
    {:ok, _} = RoomManager.dev_set_position(room.code, :north, nil)

    for pos <- [:north, :east, :south, :west],
        do: assert({:ok, _} = BotManager.start_bot(room.code, pos, :basic, 5_000))

    {:ok, seated} = RoomManager.get_room(room.code)
    seats = seated.seats

    assert MapSet.size(MapSet.new(seats, fn {_pos, seat} -> seat.bot_persona end)) == 4
    assert fourth.id in Enum.map(seats, fn {_pos, seat} -> seat.bot_persona end)

    public =
      Seat.serialize(
        Enum.find_value(seats, fn {_pos, seat} -> if seat.bot_persona == fourth.id, do: seat end)
      )

    assert public.bot_profile.name == "Fourth"
    assert public.bot_profile.avatar_url =~ "/images/bots/antti.svg"
    refute Map.has_key?(public, :bot_strategy)

    {:ok, lifecycle} = RoomManager.get_seat_lifecycle(room.code)

    lifecycle_seat =
      Enum.find_value(lifecycle.seats, fn {_pos, seat} ->
        if seat.bot_persona == fourth.id, do: seat
      end)

    assert lifecycle_seat.bot_profile == public.bot_profile

    assert Enum.sort(Map.keys(lifecycle_seat.bot_profile)) ==
             [:avatar_url, :description, :id, :name, :tempo]

    assert lifecycle_seat.username == "Fourth"
    assert lifecycle_seat.display_name == "Fourth"
    assert lifecycle_seat.avatar_url == public.bot_profile.avatar_url
    refute Map.has_key?(lifecycle_seat, :bot_strategy)
    refute Map.has_key?(lifecycle_seat, :strategy)

    unknown = %{lifecycle_seat | bot_persona: "future-persona", username: "Stale name"}

    %{seats: %{east: unknown}} =
      PidroServer.Games.SeatLifecycle.with_names(%{seats: %{east: unknown}})

    assert unknown.bot_profile == nil
    assert unknown.username == "Bot"
    assert unknown.display_name == "Bot"
    assert unknown.avatar_url == nil
  end

  test "developer host IDs that cannot be dumped as UUIDs preserve the live seat" do
    host = "warehouse worker"
    assert byte_size(host) == 16
    {:ok, room} = RoomManager.create_room(host, %{})
    assert {:ok, snapshot} = RoomManager.get_seat_lifecycle(room.code)
    assert snapshot.seats.north.player_id == host
    assert snapshot.seats.north.username == nil
  end

  test "all disabled falls back deterministically to legacy crew without empty games" do
    Repo.update_all(Profile, set: [enabled: false])
    BotCatalogue.refresh()
    assert Seat.bot_personas() == ~w(marcel antti jocke)
    assert Seat.next_bot_persona(%{}, []) == "marcel"
    assert Seat.bot_display_name("future-persona") == "Bot"
    assert Seat.serialize(Seat.new_bot(:east, nil, "future-persona")).bot_profile == nil
    {:ok, room} = RoomManager.create_room("fallback", %{})
    {:ok, pid} = BotManager.start_bot(room.code, :east, :basic, 5_000)
    assert :sys.get_state(pid).strategy == RulebookStrategy
    {:ok, seated} = RoomManager.get_room(room.code)
    assert seated.seats.east.bot_persona in ~w(marcel antti jocke)
  end

  test "assigned persona and strategy survive edits, process reattachment and rematch" do
    Repo.update_all(Profile, set: [enabled: false])
    {:ok, profile} = BotCatalogue.save(BotCatalogue.new(), %{name: "Fourth", strategy: "random"})
    user = PidroServer.AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(user.id, %{})
    {:ok, pid} = BotManager.start_bot(room.code, :east, :basic, 5_000)
    assert :sys.get_state(pid).strategy == RandomStrategy

    for pos <- [:south, :west],
        do: assert({:ok, _} = BotManager.start_bot(room.code, pos, :basic, 5_000))

    playing = PidroServer.RoomFixtures.ready_room(room.code)
    assert playing.status == :playing

    {:ok, _} =
      BotCatalogue.save(profile, %{name: "Renamed", strategy: "rulebook", enabled: false})

    assert :sys.get_state(pid).strategy == RandomStrategy
    :ok = BotManager.stop_bot(room.code, :east)
    {:ok, replacement} = BotManager.start_bot(room.code, :east, :basic, 5_000)
    assert :sys.get_state(replacement).strategy == RandomStrategy

    :ok = RoomManager.handle_player_disconnect(room.code, user.id)
    assert {:ok, reconnected} = RoomManager.handle_player_reconnect(room.code, user.id)
    assert reconnected.seats.east.bot_persona == profile.id
    assert :sys.get_state(replacement).strategy == RandomStrategy
    send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 40}})
    {:ok, finished} = RoomManager.get_room(room.code)
    assert finished.status == :finished
    {:ok, %{ready_epoch: epoch}} = RoomManager.readiness(room.code)

    assert {:ok, %{status: :playing}} =
             RoomManager.confirm_rematch(room.code, room.id, user.id, self(), epoch)

    {:ok, rematch} = RoomManager.get_room(room.code)
    assert rematch.seats.east.bot_persona == profile.id
    assert rematch.seats.east.bot_pid == replacement
    assert :sys.get_state(replacement).strategy == RandomStrategy
    assert Seat.serialize(rematch.seats.east).bot_profile.name == "Renamed"
    refute Repo.get_by(PidroServer.Profiles.PlayerProfile, user_id: profile.id)
    assert Repo.aggregate(PidroServer.Accounts.User, :count) == 1
  end
end

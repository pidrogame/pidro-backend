defmodule PidroServer.BotCatalogueTest do
  use PidroServer.DataCase, async: false
  alias PidroServer.BotCatalogue
  alias PidroServer.BotCatalogue.Profile
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Games.{Lifecycle, RoomManager, Bots.BotManager}
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
             [:avatar_url, :description, :home, :id, :lines, :name, :tempo]

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

  describe "home" do
    test "with only the legacy crew, a seeded room keeps the crew it always had" do
      # Pinned against the crews rooms got before characters had a home.
      pinned = %{
        1 => ~w(marcel jocke antti),
        2 => ~w(marcel antti jocke),
        3 => ~w(antti marcel jocke),
        4 => ~w(jocke antti marcel),
        5 => ~w(antti jocke marcel),
        6 => ~w(antti jocke marcel)
      }

      for params <- [%{}, %{rule_set: "finnish"}, %{rule_set: "louisiana"}],
          {seed, crew} <- pinned do
        {:ok, room} =
          RoomManager.create_room("host_#{inspect(params)}_#{seed}", params, seed: seed)

        assert room.bot_personas == crew
      end
    end

    test "a table puts its own crowd and the anywhere characters before the other crowd" do
      bayou = [character("Boudreaux", "louisiana"), character("Clotile", "louisiana")]
      ostrobothnia = [character("Pekka", "finland"), character("Maja", "finland")]
      anywhere = ~w(marcel antti jocke)

      orders =
        for seed <- 1..20 do
          {:ok, cajun} =
            RoomManager.create_room("cajun_#{seed}", %{rule_set: "louisiana"}, seed: seed)

          {:ok, finn} =
            RoomManager.create_room("finn_#{seed}", %{rule_set: "finnish"}, seed: seed)

          {:ok, plain} = RoomManager.create_room("plain_#{seed}", %{}, seed: seed)

          {own, rest} = Enum.split(cajun.bot_personas, 5)
          assert Enum.sort(own) == Enum.sort(bayou ++ anywhere)
          assert Enum.sort(rest) == Enum.sort(ostrobothnia)

          {own, rest} = Enum.split(finn.bot_personas, 5)
          assert Enum.sort(own) == Enum.sort(ostrobothnia ++ anywhere)
          assert Enum.sort(rest) == Enum.sort(bayou)

          # Missing rule set is Finnish.
          assert plain.bot_personas == finn.bot_personas
          cajun.bot_personas
        end

      # Each crowd is shuffled with the seed, not seated in catalogue order.
      assert orders |> Enum.map(&hd/1) |> Enum.uniq() |> length() > 1
      assert orders |> Enum.map(&Enum.drop(&1, 5)) |> Enum.uniq() |> length() == 2
    end

    test "a room reaches the other crowd only when its own is exhausted, and later bots follow its order" do
      Repo.update_all(Profile, set: [enabled: false])
      bayou = [character("Boudreaux", "louisiana"), character("Clotile", "louisiana")]
      ostrobothnia = [character("Pekka", "finland"), character("Maja", "finland")]

      for seed <- 1..10 do
        {:ok, room} =
          RoomManager.create_room("host_#{seed}", %{rule_set: "louisiana"}, seed: seed)

        assert Enum.sort(Enum.take(room.bot_personas, 2)) == Enum.sort(bayou)
      end

      {:ok, room} = RoomManager.create_room("host", %{rule_set: "louisiana"}, seed: 7)

      # One from the host's seat picker, two through the bot manager's join.
      assert {:ok, _} = RoomManager.set_seat(room.code, "host", :east, :bot)

      for pos <- [:south, :west],
          do:
            assert(
              {:ok, _, ^pos} = RoomManager.join_bot(room.code, bot_id(room, pos), self(), pos)
            )

      {:ok, seated} = RoomManager.get_room(room.code)

      assert Enum.sort([seated.seats.east.bot_persona, seated.seats.south.bot_persona]) ==
               Enum.sort(bayou)

      assert seated.seats.west.bot_persona == Enum.at(room.bot_personas, 2)
      assert seated.seats.west.bot_persona in ostrobothnia

      # The bayou character leaves; the bot taking the seat is from the bayou again.
      freed = seated.seats.south.bot_persona
      assert :ok = RoomManager.leave_room(bot_id(room, :south))

      assert {:ok, _, :south} =
               RoomManager.join_bot(room.code, bot_id(room, :south), self(), :south)

      {:ok, refilled} = RoomManager.get_room(room.code)
      assert refilled.seats.south.bot_persona == freed
    end

    test "a room with none of its own crowd still fills" do
      Repo.update_all(Profile, set: [enabled: false])
      ostrobothnia = for name <- ~w(Pekka Maja Lasse), do: character(name, "finland")
      {:ok, room} = RoomManager.create_room("host", %{rule_set: "louisiana"}, seed: 3)

      for pos <- [:east, :south, :west],
          do:
            assert(
              {:ok, _, ^pos} = RoomManager.join_bot(room.code, bot_id(room, pos), self(), pos)
            )

      {:ok, seated} = RoomManager.get_room(room.code)
      crew = Enum.map([:east, :south, :west], &seated.seats[&1].bot_persona)
      assert Enum.sort(crew) == Enum.sort(ostrobothnia)
    end

    test "a character's home is anywhere, finland or louisiana" do
      assert BotCatalogue.new().home == "anywhere"
      assert Enum.map(BotCatalogue.list(), & &1.home) == ~w(anywhere anywhere anywhere)
      refute BotCatalogue.change(BotCatalogue.new(), %{name: "X", home: "texas"}).valid?
      assert BotCatalogue.change(BotCatalogue.new(), %{name: "X", home: "louisiana"}).valid?

      assert_raise Postgrex.Error, ~r/supported_home/, fn ->
        Repo.update_all(Profile, set: [home: "texas"])
      end
    end

    test "lines are trimmed, blank ones dropped, at most eight of at most 40 characters" do
      lines = fn lines -> BotCatalogue.change(BotCatalogue.new(), %{name: "X", lines: lines}) end

      changeset = lines.(["  Hmm, jaha…  ", "", "   ", "Let's see…"])
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :lines) == ["Hmm, jaha…", "Let's see…"]
      assert BotCatalogue.new().lines == []

      # Characters, not bytes, and counted after trimming.
      assert lines.(["  " <> String.duplicate("ä", 40) <> "  "]).valid?
      refute lines.([String.duplicate("a", 41)]).valid?

      assert lines.(List.duplicate("Väntä lite…", 8) ++ [" "]).valid?
      refute lines.(List.duplicate("Väntä lite…", 9)).valid?
    end

    test "public profiles and seated bots carry the home and lines" do
      {:ok, profile} =
        BotCatalogue.save(BotCatalogue.get!("antti"), %{home: "finland", lines: ["Hmm, jaha…"]})

      assert %{home: "finland", lines: ["Hmm, jaha…"]} = BotCatalogue.public(profile)
      assert %{home: "anywhere", lines: []} = BotCatalogue.public(BotCatalogue.profile("marcel"))
      assert %{home: "anywhere", lines: []} = BotCatalogue.public(hd(BotCatalogue.defaults()))

      bot_profile = Seat.serialize(Seat.new_bot(:east, nil, "antti")).bot_profile
      assert %{home: "finland", lines: ["Hmm, jaha…"]} = bot_profile
    end
  end

  describe "tempo" do
    # Each bot's move lands on a room without that turn, and says so.
    @describetag :capture_log

    setup do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original,
          bot_delay_ms: 600,
          own_bot_delay_ms: 800,
          bot_delay_variance_ms: 0,
          bot_min_delay_ms: 5,
          turn_timer_bid_ms: 60_000,
          turn_timer_play_ms: 60_000
        )
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
    end

    test "the legacy crew is steady, and public profiles carry the tempo" do
      assert Enum.map(BotCatalogue.list(), & &1.tempo) == ~w(steady steady steady)
      assert BotCatalogue.public(BotCatalogue.profile("marcel")).tempo == "steady"
    end

    test "each character acts on its tempo's beat, at quick and at own pace" do
      tempos = %{"marcel" => "quick", "antti" => "steady", "jocke" => "slow"}

      for {id, tempo} <- tempos,
          do: {:ok, _} = BotCatalogue.save(BotCatalogue.get!(id), %{tempo: tempo})

      {:ok, room} = RoomManager.create_room("host", %{})

      bots =
        for pos <- [:east, :south, :west] do
          {:ok, pid} = BotManager.start_bot(room.code, pos, :basic)
          {:ok, seated} = RoomManager.get_room(room.code)
          {seated.seats[pos].bot_persona, pid, pos}
        end

      assert Enum.sort(for {persona, _, _} <- bots, do: persona) == ~w(antti jocke marcel)

      expected = %{
        quick: %{"marcel" => 450, "antti" => 600, "jocke" => 780},
        own: %{"marcel" => 600, "antti" => 800, "jocke" => 1040}
      }

      for pace <- [:quick, :own] do
        beats = beats(room.code, bots, pace)
        for {persona, ms} <- expected[pace], do: assert_beat(beats[persona], ms)
      end
    end

    test "the dev panel's fixed delay beats the character's tempo" do
      # Quick, so a tempo applied on top of the fixed delay (188 ms) falls outside the beat.
      Repo.update_all(Profile, set: [tempo: "quick"])
      BotCatalogue.refresh()
      {:ok, room} = RoomManager.create_room("host", %{})
      {:ok, pid} = BotManager.start_bot(room.code, :east, :basic, 250)
      assert_beat(beats(room.code, [{:east, pid, :east}], :quick)[:east], 250)
    end

    test "a character with no tempo, or no character, is steady" do
      :persistent_term.put(BotCatalogue, Enum.map(BotCatalogue.defaults(), &%{&1 | tempo: nil}))
      {:ok, room} = RoomManager.create_room("host", %{})
      {:ok, pid} = BotManager.start_bot(room.code, :east, :basic)
      assert_beat(beats(room.code, [{:east, pid, :east}], :quick)[:east], 600)
      assert_beat(beats(room.code, [{:east, pid, :east}], :own)[:east], 800)
    end

    test "a substitute keeps its seat's character's tempo; one for a human is steady" do
      Repo.update_all(Profile, set: [tempo: "slow"])
      BotCatalogue.refresh()
      [host, south, west] = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)
      {:ok, room} = RoomManager.create_room(host, %{})
      # A character whose process dies mid-game, so its departure seats a substitute.
      character = spawn(fn -> receive do: (:never -> :ok) end)
      bot_id = "bot_#{room.code}_east"
      {:ok, _, :east} = RoomManager.join_bot(room.code, bot_id, character, :east)
      {:ok, _, :south} = RoomManager.join_room(room.code, south, :south)
      {:ok, _, :west} = RoomManager.join_room(room.code, west, :west)
      PidroServer.RoomFixtures.ready_room(room.code)
      assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)

      ref = Process.monitor(character)
      Process.exit(character, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      :ok = RoomManager.leave_room(bot_id)
      :ok = RoomManager.leave_room(south)
      {:ok, room} = RoomManager.get_room(room.code)
      assert %{status: :bot_substitute, bot_persona: persona} = room.seats.east
      assert is_binary(persona)
      assert %{status: :bot_substitute, bot_persona: nil} = room.seats.south

      subs = for pos <- [:east, :south], do: {pos, room.seats[pos].bot_pid, pos}
      beats = beats(room.code, subs, :quick)
      assert_beat(beats[:east], 780)
      assert_beat(beats[:south], 600)
    end
  end

  # When each bot acts once the turn reaches it, read from its own mailbox:
  # from the update that gives it the turn to its own `:make_move`.
  defp beats(room_code, bots, pace) do
    for {_key, pid, _pos} <- bots do
      wait_until_idle(pid)
      :erlang.trace(pid, true, [:receive, :monotonic_timestamp])
    end

    for {_key, pid, pos} <- bots do
      turn = %{phase: :bidding, current_turn: pos, config: %{pace: pace}}
      send(pid, {:state_update, room_code, %{state: turn, transition_delay_ms: 0}})
    end

    Map.new(bots, &beat/1)
  end

  defp beat({key, pid, _pos}) do
    assert_receive {:trace_ts, ^pid, :receive, {:state_update, _, %{state: _}}, from}, 1_000
    assert_receive {:trace_ts, ^pid, :receive, :make_move, to}, 3_000
    :erlang.trace(pid, false, [:receive, :monotonic_timestamp])
    {key, System.convert_time_unit(to - from, :native, :millisecond)}
  end

  # A move already pending from the real game must not stand in for ours.
  defp wait_until_idle(pid, attempts \\ 300) do
    cond do
      not :sys.get_state(pid).move_scheduled? -> :ok
      attempts == 0 -> flunk("the bot never finished its pending move")
      true -> Process.sleep(10) && wait_until_idle(pid, attempts - 1)
    end
  end

  defp assert_beat(ms, expected) do
    assert ms in (expected - 1)..(expected + 100),
           "expected a #{expected} ms beat, got #{inspect(ms)} ms"
  end

  defp character(name, home) do
    {:ok, profile} = BotCatalogue.save(BotCatalogue.new(), %{name: name, home: home})
    profile.id
  end

  defp bot_id(room, position), do: "bot_#{room.code}_#{position}"
end

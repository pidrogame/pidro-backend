defmodule PidroServer.Games.Room.SeatTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Room.Seat

  test "connection totals retain network durations and count answered and unanswered probes" do
    seat =
      Seat.new_human(:north, "user")
      |> Seat.connection_network("wifi")
      |> Seat.start_connection_stats(1000)
      |> Seat.record_connection_probe()
      |> Seat.record_connection_reply(42)
      |> Seat.connection_network("cellular", 301_000)
      |> Seat.record_connection_probe()
      |> Seat.record_connection_probe()
      |> Seat.record_connection_reply(2000)

    totals = Seat.connection_totals(seat, 901_000)
    assert totals.duration_seconds == 900
    assert totals.network_ms == %{"wifi" => 300_000, "cellular" => 600_000}
    assert totals.checks_sent == 3
    assert totals.unanswered_checks == 1
    assert totals.rtt_histogram == %{"42" => 1, "2000" => 1}
    assert totals.disconnected_seconds == 0
    finished = Seat.finish_connection_stats(seat, 901_000)
    assert Seat.connection_totals(finished, 9_001_000) == totals

    assert Seat.connection_totals(Seat.start_connection_stats(seat, 901_000), 901_000).checks_sent ==
             0
  end

  describe "creation" do
    test "new_human creates a connected human seat" do
      seat = Seat.new_human(:north, "user-1")

      assert seat.position == :north
      assert seat.occupant_type == :human
      assert seat.user_id == "user-1"
      assert seat.status == :connected
      assert seat.is_owner == false
      assert %DateTime{} = seat.joined_at
      assert seat.bot_pid == nil
      assert seat.disconnected_at == nil
      assert seat.grace_expires_at == nil
      assert seat.reserved_for == nil
    end

    test "new_human with is_owner option" do
      seat = Seat.new_human(:south, "user-2", is_owner: true)

      assert seat.is_owner == true
    end

    test "new_human with joined_at option" do
      joined = ~U[2026-01-01 12:00:00Z]
      seat = Seat.new_human(:east, "user-3", joined_at: joined)

      assert seat.joined_at == joined
    end

    test "new_bot creates a connected bot seat" do
      pid = self()
      seat = Seat.new_bot(:west, pid)

      assert seat.position == :west
      assert seat.occupant_type == :bot
      assert seat.bot_pid == pid
      assert seat.status == :connected
      assert seat.user_id == nil
      assert seat.is_owner == false
      assert seat.joined_at == nil
    end

    test "new_vacant creates a vacant seat with nil status" do
      seat = Seat.new_vacant(:east)

      assert seat.position == :east
      assert seat.occupant_type == :vacant
      assert seat.status == nil
      assert seat.user_id == nil
      assert seat.bot_pid == nil
      assert seat.is_owner == false
    end
  end

  describe "valid transitions" do
    test "disconnect from connected human" do
      seat = Seat.new_human(:north, "user-1")
      assert {:ok, disconnected} = Seat.disconnect(seat)

      assert disconnected.status == :reconnecting
      assert %DateTime{} = disconnected.disconnected_at
      assert disconnected.occupant_type == :human
      assert disconnected.user_id == "user-1"
    end

    test "start_grace from reconnecting" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)

      grace_expires = DateTime.add(DateTime.utc_now(), 120, :second)
      assert {:ok, grace} = Seat.start_grace(reconnecting, grace_expires)

      assert grace.status == :grace
      assert grace.grace_expires_at == grace_expires
      assert grace.reserved_for == "user-1"
      assert grace.user_id == "user-1"
    end

    test "substitute_bot from grace" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)
      {:ok, grace} = Seat.start_grace(reconnecting, DateTime.utc_now())

      bot_pid = self()
      assert {:ok, botted} = Seat.substitute_bot(grace, bot_pid)

      assert botted.status == :bot_substitute
      assert botted.occupant_type == :bot
      assert botted.bot_pid == bot_pid
      assert botted.user_id == nil
      assert botted.reserved_for == "user-1"
    end

    test "make_permanent_bot from bot_substitute" do
      seat = build_bot_substitute("user-1")
      assert {:ok, permanent} = Seat.make_permanent_bot(seat)

      assert permanent.status == :bot_substitute
      assert permanent.reserved_for == nil
    end

    test "reclaim from reconnecting (Phase 1)" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)

      assert {:ok, reclaimed} = Seat.reclaim(reconnecting, "user-1")

      assert reclaimed.status == :connected
      assert reclaimed.occupant_type == :human
      assert reclaimed.user_id == "user-1"
      assert reclaimed.disconnected_at == nil
    end

    test "reclaim from grace (Phase 2)" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)
      {:ok, grace} = Seat.start_grace(reconnecting, DateTime.utc_now())
      {:ok, _botted} = Seat.substitute_bot(grace, self())

      # reclaim works from :grace status, not :bot_substitute
      seat2 = Seat.new_human(:south, "user-2")
      {:ok, reconnecting2} = Seat.disconnect(seat2)
      {:ok, grace2} = Seat.start_grace(reconnecting2, DateTime.utc_now())

      assert {:ok, reclaimed} = Seat.reclaim(grace2, "user-2")

      assert reclaimed.status == :connected
      assert reclaimed.occupant_type == :human
      assert reclaimed.user_id == "user-2"
      assert reclaimed.bot_pid == nil
      assert reclaimed.disconnected_at == nil
      assert reclaimed.grace_expires_at == nil
      assert reclaimed.reserved_for == nil
    end

    test "open_for_substitute from bot_substitute" do
      seat = build_bot_substitute("user-1")
      assert {:ok, vacant} = Seat.open_for_substitute(seat)

      assert vacant.status == nil
      assert vacant.occupant_type == :vacant
      assert vacant.bot_pid == nil
      assert vacant.user_id == nil
      assert vacant.reserved_for == nil
      assert vacant.disconnected_at == nil
      assert vacant.grace_expires_at == nil
    end

    test "fill_seat from vacant" do
      seat = Seat.new_vacant(:north)
      assert {:ok, filled} = Seat.fill_seat(seat, "new-user")

      assert filled.status == :connected
      assert filled.occupant_type == :human
      assert filled.user_id == "new-user"
      assert %DateTime{} = filled.joined_at
    end

    test "full lifecycle: connected -> reconnecting -> grace -> bot_substitute -> vacant -> connected" do
      # Phase 0: connected human
      seat = Seat.new_human(:north, "user-1", is_owner: true)
      assert seat.status == :connected

      # Phase 1: disconnect
      {:ok, seat} = Seat.disconnect(seat)
      assert seat.status == :reconnecting

      # Phase 2: grace + bot
      {:ok, seat} = Seat.start_grace(seat, DateTime.utc_now())
      assert seat.status == :grace
      {:ok, seat} = Seat.substitute_bot(seat, self())
      assert seat.status == :bot_substitute

      # Phase 3: permanent
      {:ok, seat} = Seat.make_permanent_bot(seat)
      assert seat.reserved_for == nil

      # Owner opens seat
      {:ok, seat} = Seat.open_for_substitute(seat)
      assert seat.occupant_type == :vacant

      # New human fills seat
      {:ok, seat} = Seat.fill_seat(seat, "user-2")
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == "user-2"
    end
  end

  describe "invalid transitions" do
    test "disconnect from grace returns error" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)
      {:ok, grace} = Seat.start_grace(reconnecting, DateTime.utc_now())

      assert {:error, :invalid_transition} = Seat.disconnect(grace)
    end

    test "disconnect from bot returns error" do
      seat = Seat.new_bot(:north, self())
      assert {:error, :invalid_transition} = Seat.disconnect(seat)
    end

    test "disconnect from vacant returns error" do
      seat = Seat.new_vacant(:north)
      assert {:error, :invalid_transition} = Seat.disconnect(seat)
    end

    test "disconnect from reconnecting returns error" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)

      assert {:error, :invalid_transition} = Seat.disconnect(reconnecting)
    end

    test "substitute_bot from connected returns error" do
      seat = Seat.new_human(:north, "user-1")
      assert {:error, :invalid_transition} = Seat.substitute_bot(seat, self())
    end

    test "substitute_bot from reconnecting returns error" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)

      assert {:error, :invalid_transition} = Seat.substitute_bot(reconnecting, self())
    end

    test "start_grace from connected returns error" do
      seat = Seat.new_human(:north, "user-1")
      assert {:error, :invalid_transition} = Seat.start_grace(seat, DateTime.utc_now())
    end

    test "make_permanent_bot from grace returns error" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)
      {:ok, grace} = Seat.start_grace(reconnecting, DateTime.utc_now())

      assert {:error, :invalid_transition} = Seat.make_permanent_bot(grace)
    end

    test "reclaim with wrong user_id from reconnecting returns user_mismatch" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)

      assert {:error, :user_mismatch} = Seat.reclaim(reconnecting, "wrong-user")
    end

    test "reclaim with wrong user_id from grace returns user_mismatch" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, reconnecting} = Seat.disconnect(seat)
      {:ok, grace} = Seat.start_grace(reconnecting, DateTime.utc_now())

      assert {:error, :user_mismatch} = Seat.reclaim(grace, "wrong-user")
    end

    test "reclaim from bot_substitute with matching reserved_for succeeds" do
      seat = build_bot_substitute("user-1")
      assert {:ok, reclaimed} = Seat.reclaim(seat, "user-1")
      assert reclaimed.status == :connected
      assert reclaimed.occupant_type == :human
      assert reclaimed.user_id == "user-1"
      assert reclaimed.bot_pid == nil
      assert reclaimed.reserved_for == nil
    end

    test "reclaim from permanent bot_substitute returns user_mismatch" do
      seat = build_bot_substitute("user-1")
      {:ok, permanent} = Seat.make_permanent_bot(seat)
      assert {:error, :user_mismatch} = Seat.reclaim(permanent, "user-1")
    end

    test "reclaim from bot_substitute with wrong user returns user_mismatch" do
      seat = build_bot_substitute("user-1")
      assert {:error, :user_mismatch} = Seat.reclaim(seat, "wrong-user")
    end

    test "reclaim from connected returns error" do
      seat = Seat.new_human(:north, "user-1")
      assert {:error, :invalid_transition} = Seat.reclaim(seat, "user-1")
    end

    test "fill_seat on non-vacant seat returns error" do
      seat = Seat.new_human(:north, "user-1")
      assert {:error, :invalid_transition} = Seat.fill_seat(seat, "user-2")
    end

    test "open_for_substitute from connected returns error" do
      seat = Seat.new_human(:north, "user-1")
      assert {:error, :invalid_transition} = Seat.open_for_substitute(seat)
    end
  end

  describe "queries" do
    test "connected_human? is true for connected human" do
      assert Seat.connected_human?(Seat.new_human(:north, "user-1"))
    end

    test "connected_human? is false for bot" do
      refute Seat.connected_human?(Seat.new_bot(:north, self()))
    end

    test "connected_human? is false for vacant" do
      refute Seat.connected_human?(Seat.new_vacant(:north))
    end

    test "connected_human? is false for reconnecting human" do
      {:ok, seat} = Seat.disconnect(Seat.new_human(:north, "user-1"))
      refute Seat.connected_human?(seat)
    end

    test "active_bot? is true for bot with pid" do
      assert Seat.active_bot?(Seat.new_bot(:north, self()))
    end

    test "active_bot? is true for bot_substitute with pid" do
      seat = build_bot_substitute("user-1")
      assert Seat.active_bot?(seat)
    end

    test "active_bot? is false for human" do
      refute Seat.active_bot?(Seat.new_human(:north, "user-1"))
    end

    test "active_bot? is false for vacant" do
      refute Seat.active_bot?(Seat.new_vacant(:north))
    end

    test "can_reclaim? is true for reconnecting seat with matching user_id" do
      {:ok, seat} = Seat.disconnect(Seat.new_human(:north, "user-1"))
      assert Seat.can_reclaim?(seat, "user-1")
    end

    test "can_reclaim? is true for grace seat with matching reserved_for" do
      {:ok, seat} = Seat.disconnect(Seat.new_human(:north, "user-1"))
      {:ok, seat} = Seat.start_grace(seat, DateTime.utc_now())
      assert Seat.can_reclaim?(seat, "user-1")
    end

    test "can_reclaim? is false for wrong user" do
      {:ok, seat} = Seat.disconnect(Seat.new_human(:north, "user-1"))
      refute Seat.can_reclaim?(seat, "wrong-user")
    end

    test "can_reclaim? is false for connected seat" do
      refute Seat.can_reclaim?(Seat.new_human(:north, "user-1"), "user-1")
    end

    test "can_reclaim? is false for bot_substitute (Phase 3)" do
      seat = build_bot_substitute("user-1")
      {:ok, permanent} = Seat.make_permanent_bot(seat)
      refute Seat.can_reclaim?(permanent, "user-1")
    end

    test "vacant? is true for vacant seat" do
      assert Seat.vacant?(Seat.new_vacant(:north))
    end

    test "vacant? is false for human seat" do
      refute Seat.vacant?(Seat.new_human(:north, "user-1"))
    end

    test "vacant? is true after open_for_substitute" do
      seat = build_bot_substitute("user-1")
      {:ok, opened} = Seat.open_for_substitute(seat)
      assert Seat.vacant?(opened)
    end

    test "owner? is true when is_owner is true" do
      seat = Seat.new_human(:north, "user-1", is_owner: true)
      assert Seat.owner?(seat)
    end

    test "owner? is false when is_owner is false" do
      refute Seat.owner?(Seat.new_human(:north, "user-1"))
    end

    test "position_of finds a seated player, connected or not, but not one a bot plays for" do
      {:ok, reconnecting} = Seat.disconnect(Seat.new_human(:south, "dropped"))

      {:ok, permanent} =
        Seat.make_permanent_bot(%{build_bot_substitute("gone") | position: :west})

      seats = %{
        north: Seat.new_human(:north, "seated"),
        east: %{build_bot_substitute("away") | position: :east},
        south: reconnecting,
        west: permanent
      }

      assert Seat.position_of(seats, "seated") == :north
      assert Seat.position_of(seats, "dropped") == :south
      assert Seat.position_of(seats, "away") == nil
      assert Seat.position_of(seats, "gone") == nil
    end
  end

  describe "bot personas" do
    test "a bot takes the first of marcel, antti, jocke no other seat holds" do
      pid = self()
      assert Seat.next_bot_persona(%{}) == "marcel"

      seats = %{
        north: Seat.new_human(:north, "user-1"),
        east: Seat.new_bot(:east, pid, "marcel"),
        south: Seat.new_bot(:south, pid, "jocke"),
        west: Seat.new_vacant(:west)
      }

      assert Seat.next_bot_persona(seats) == "antti"
    end

    test "a substitute bot holds no persona, so it does not take one" do
      {:ok, grace} =
        Seat.new_human(:east, "user-1")
        |> Seat.disconnect()
        |> elem(1)
        |> Seat.start_grace(DateTime.utc_now())

      {:ok, substitute} = Seat.substitute_bot(grace, self())

      assert substitute.bot_persona == nil
      assert Seat.next_bot_persona(%{east: substitute}) == "marcel"
    end

    test "the fourth bot at an all-bot table reuses marcel" do
      seats =
        Map.new(Enum.zip([:north, :east, :south], ~w(marcel antti jocke)), fn {pos, persona} ->
          {pos, Seat.new_bot(pos, self(), persona)}
        end)

      assert Seat.next_bot_persona(seats) == "marcel"
    end

    test "personas show as Marcel, Antti and Jocke" do
      assert Enum.map(~w(marcel antti jocke), &Seat.bot_display_name/1) ==
               ["Marcel", "Antti", "Jocke"]
    end
  end

  describe "serialization" do
    test "serialize returns a map with no Elixir-specific types" do
      joined = ~U[2026-03-08 10:00:00Z]
      seat = Seat.new_human(:north, "user-1", is_owner: true, joined_at: joined)
      serialized = Seat.serialize(seat)

      assert is_map(serialized)
      assert serialized.position == :north
      assert serialized.occupant_type == :human
      assert serialized.user_id == "user-1"
      assert serialized.status == :connected
      assert serialized.is_owner == true
      assert serialized.joined_at == "2026-03-08T10:00:00Z"
      assert serialized.disconnected_at == nil
      assert serialized.grace_expires_at == nil
      assert serialized.has_reservation == false
    end

    test "serialize excludes bot_pid" do
      seat = Seat.new_bot(:west, self())
      serialized = Seat.serialize(seat)

      refute Map.has_key?(serialized, :bot_pid)
    end

    test "serialize converts DateTimes to ISO 8601 strings" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, disconnected} = Seat.disconnect(seat)
      serialized = Seat.serialize(disconnected)

      assert is_binary(serialized.disconnected_at)
      assert {:ok, _, _} = DateTime.from_iso8601(serialized.disconnected_at)
    end

    test "serialize handles vacant seat" do
      seat = Seat.new_vacant(:east)
      serialized = Seat.serialize(seat)

      assert serialized.position == :east
      assert serialized.occupant_type == :vacant
      assert serialized.status == nil
      assert serialized.user_id == nil
    end

    test "serialize handles grace seat with all temporal fields" do
      seat = Seat.new_human(:north, "user-1")
      {:ok, seat} = Seat.disconnect(seat)
      grace_at = ~U[2026-03-08 12:00:00Z]
      {:ok, seat} = Seat.start_grace(seat, grace_at)

      serialized = Seat.serialize(seat)

      assert is_binary(serialized.disconnected_at)
      assert serialized.grace_expires_at == "2026-03-08T12:00:00Z"
      assert serialized.has_reservation == true
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_bot_substitute(original_user_id) do
    seat = Seat.new_human(:north, original_user_id)
    {:ok, seat} = Seat.disconnect(seat)
    {:ok, seat} = Seat.start_grace(seat, DateTime.utc_now())
    {:ok, seat} = Seat.substitute_bot(seat, self())
    seat
  end
end

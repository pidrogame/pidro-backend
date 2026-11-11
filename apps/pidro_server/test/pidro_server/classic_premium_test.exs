defmodule PidroServer.ClassicPremiumTest do
  use PidroServer.DataCase, async: true

  import ExUnit.CaptureLog
  import PidroServer.ClassicPremiumFixtures

  alias PidroServer.AccountsFixtures
  alias PidroServer.ClassicPremium
  alias PidroServer.ClassicPremium.{Carryover, Retry}
  alias PidroServer.Entitlements
  alias PidroServer.Entitlements.Entitlement
  alias PidroServer.Profiles

  defp classic_user(legacy_premium \\ true) do
    user = AccountsFixtures.user_fixture()

    user =
      user
      |> Ecto.Changeset.change(
        classic_user_id: System.unique_integer([:positive]),
        classic_claimed_at: DateTime.utc_now()
      )
      |> Repo.update!()

    {:ok, _profile} = Profiles.import_legacy_progression(user.id, %{premium: legacy_premium})
    user
  end

  defp premium(user, attrs) do
    Repo.insert!(
      struct(
        %Entitlement{user_id: user.id, entitlement: "premium", active: true, source: "store"},
        attrs
      )
    )
  end

  defp ms(datetime), do: DateTime.to_unix(datetime, :millisecond)

  describe "carry_over/1" do
    test "a running Classic Premium is granted until Classic's date" do
      user = classic_user()
      until = days_from_now(60)
      stub_classic(DateTime.to_iso8601(until))
      fake_revenuecat()

      assert {:ok, %Carryover{} = row} = ClassicPremium.carry_over(user)

      id = Integer.to_string(user.classic_user_id)
      assert_received {:classic_lookup, %{"id" => ^id}}
      expected_ms = ms(until)
      path = "/v1/subscribers/#{user.id}/entitlements/premium/promotional"
      assert_received {:revenuecat_grant, ^path, ^expected_ms}

      assert %{state: "granted", classic_premium_until: ^until, attempts: 0, last_error: nil} =
               row

      assert %Entitlement{source: "classic_honored", expires_at: ^until, active: true} =
               Entitlements.get(user.id)

      assert Entitlements.premium_fields(user) == %{
               premium: true,
               premium_until: until,
               premium_source: "classic_honored"
             }
    end

    test "a grant stops at 13 months; the row keeps Classic's real date" do
      user = classic_user()
      until = days_from_now(3 * 365)
      stub_classic(DateTime.to_iso8601(until))
      fake_revenuecat()

      before = DateTime.utc_now() |> DateTime.shift(month: 13) |> DateTime.truncate(:second)
      assert {:ok, row} = ClassicPremium.carry_over(user)
      later = DateTime.utc_now() |> DateTime.shift(month: 13)

      assert_received {:revenuecat_grant, _path, end_ms}
      assert end_ms >= ms(before) and end_ms <= ms(later)
      assert end_ms < ms(until)
      assert %{state: "granted", classic_premium_until: ^until} = row
    end

    test "an ended Classic Premium is `ended` with its date, none at all is `none`" do
      ended = classic_user()
      until = days_from_now(-10)
      stub_classic(DateTime.to_iso8601(until))
      fake_revenuecat()

      assert {:ok, %{state: "ended", classic_premium_until: ^until}} =
               ClassicPremium.carry_over(ended)

      never = classic_user(false)
      stub_classic(nil)

      assert {:ok, %{state: "none", classic_premium_until: nil}} =
               ClassicPremium.carry_over(never)

      refute_received {:revenuecat_grant, _, _}
      assert Entitlements.get(ended.id) == nil
    end

    test "Classic writes a date without an offset: it is UTC" do
      user = classic_user()
      until = days_from_now(30)
      stub_classic(until |> DateTime.to_naive() |> NaiveDateTime.to_iso8601())
      fake_revenuecat()

      assert {:ok, %{state: "granted", classic_premium_until: ^until}} =
               ClassicPremium.carry_over(user)
    end

    test "already Premium from a store is `imported` without asking anyone" do
      user = classic_user()
      premium(user, expires_at: days_from_now(200))
      stub_classic(DateTime.to_iso8601(days_from_now(60)))
      fake_revenuecat()

      assert {:ok, %{state: "imported", classic_premium_until: nil}} =
               ClassicPremium.carry_over(user)

      refute_received {:classic_lookup, _}
      refute_received {:revenuecat_grant, _, _}

      # Control: a lapsed store row does not count.
      lapsed = classic_user()
      premium(lapsed, expires_at: days_from_now(-1))
      assert {:ok, %{state: "granted"}} = ClassicPremium.carry_over(lapsed)
      assert_received {:classic_lookup, _}
    end

    test "Classic down or RevenueCat down leaves `pending`, counts the attempt and logs it" do
      user = classic_user()
      stub_classic({:status, 503})
      fake_revenuecat()

      {result, log} = with_log(fn -> ClassicPremium.carry_over(user) end)

      assert {:ok,
              %{state: "pending", attempts: 1, last_error: error, last_tried_at: %DateTime{}}} =
               result

      assert error =~ "provider_unavailable"
      assert log =~ "[error]"
      assert log =~ user.id

      {{:ok, again}, _log} = with_log(fn -> ClassicPremium.carry_over(user) end)
      assert %{state: "pending", attempts: 2} = again

      # Classic verified this id at claim: not finding it now is a failure too.
      stub_classic({:status, 404})
      {{:ok, missing}, _log} = with_log(fn -> ClassicPremium.carry_over(user) end)
      assert %{state: "pending", attempts: 3, last_error: "{:classic, :not_found}"} = missing

      # Back up: granted, and the failures are behind it.
      stub_classic(DateTime.to_iso8601(days_from_now(60)))

      assert {:ok, %{state: "granted", attempts: 0, last_error: nil}} =
               ClassicPremium.carry_over(user)

      rc_down = classic_user()
      stub_classic(DateTime.to_iso8601(days_from_now(60)))
      fake_revenuecat({:status, 500})

      {result, log} = with_log(fn -> ClassicPremium.carry_over(rc_down) end)
      assert {:ok, %{state: "pending", attempts: 1, last_error: error}} = result
      assert error =~ "revenuecat_status, 500"
      assert log =~ rc_down.id
      assert Entitlements.get(rc_down.id) == nil
    end

    test "a crash inside is recorded as `pending`, never raised" do
      user = classic_user()
      Req.Test.stub(PidroServer.Accounts.ClassicClient, fn _conn -> raise "boom" end)

      {result, _log} = with_log(fn -> ClassicPremium.carry_over(user) end)
      assert {:ok, %{state: "pending", attempts: 1, last_error: "boom"}} = result
    end

    test "again: extends only when Classic's date moved, or a capped grant runs out" do
      user = classic_user()
      first = days_from_now(60)
      stub_classic(DateTime.to_iso8601(first))
      fake_revenuecat()
      assert {:ok, %{state: "granted"}} = ClassicPremium.carry_over(user)
      assert_received {:revenuecat_grant, _, _}

      # Same date: nothing to do.
      assert {:ok, %{state: "granted", classic_premium_until: ^first}} =
               ClassicPremium.carry_over(user)

      refute_received {:revenuecat_grant, _, _}

      # HQ renewed: Classic's date moved forward.
      renewed = days_from_now(90)
      stub_classic(DateTime.to_iso8601(renewed))

      assert {:ok, %{state: "granted", classic_premium_until: ^renewed}} =
               ClassicPremium.carry_over(user)

      renewed_ms = ms(renewed)
      assert_received {:revenuecat_grant, _, ^renewed_ms}
      assert %Entitlement{expires_at: ^renewed} = Entitlements.get(user.id)

      # Classic down for a granted player: still granted, the attempt counted.
      stub_classic({:status, 503})
      {result, _log} = with_log(fn -> ClassicPremium.carry_over(user) end)
      assert {:ok, %{state: "granted", attempts: 1}} = result
    end

    test "a grant the cap cut short is extended once it ends within 30 days" do
      far = days_from_now(3 * 365)

      for {ends_in, extended?} <- [{10, true}, {100, false}] do
        user = classic_user()

        Repo.insert!(%Carryover{
          user_id: user.id,
          classic_user_id: user.classic_user_id,
          state: "granted",
          classic_premium_until: far
        })

        premium(user,
          source: "classic_honored",
          store: "promotional",
          expires_at: days_from_now(ends_in)
        )

        stub_classic(DateTime.to_iso8601(far))
        fake_revenuecat()

        assert {:ok, %{state: "granted"}} = ClassicPremium.carry_over(user)

        if extended?,
          do: assert_received({:revenuecat_grant, _, _}),
          else: refute_received({:revenuecat_grant, _, _})
      end
    end

    test "a player without a Classic link is left alone" do
      user = AccountsFixtures.user_fixture()
      assert ClassicPremium.carry_over(user) == {:ok, nil}
      assert Repo.aggregate(Carryover, :count) == 0
    end
  end

  describe "answer/1" do
    defp row(user, state, until),
      do: %Carryover{user_id: user.id, state: state, classic_premium_until: until}

    test "says carried, recently ended, or pending to a Classic subscriber; else nothing" do
      subscriber = classic_user(true)
      free = classic_user(false)
      until = days_from_now(60)
      recent = DateTime.utc_now() |> DateTime.shift(month: -11) |> DateTime.truncate(:second)
      old = DateTime.utc_now() |> DateTime.shift(month: -13) |> DateTime.truncate(:second)

      assert ClassicPremium.answer(row(subscriber, "granted", until)) ==
               %{state: "carried", until: until}

      assert ClassicPremium.answer(row(subscriber, "imported", nil)) ==
               %{state: "carried", until: nil}

      assert ClassicPremium.answer(row(free, "ended", recent)) == %{state: "ended", until: recent}
      assert ClassicPremium.answer(row(free, "ended", old)) == nil

      assert ClassicPremium.answer(row(subscriber, "pending", nil)) == %{
               state: "pending",
               until: nil
             }

      assert ClassicPremium.answer(row(free, "pending", nil)) == nil
      assert ClassicPremium.answer(row(free, "none", nil)) == nil
      assert ClassicPremium.answer(nil) == nil
    end
  end

  describe "queue_claimed/0" do
    test "queues every claimed Classic subscriber without a row, once" do
      waiting = classic_user(true)
      also_waiting = classic_user(true)
      tried = classic_user(true)
      _free = classic_user(false)

      Repo.insert!(%Carryover{
        user_id: tried.id,
        classic_user_id: tried.classic_user_id,
        state: "ended"
      })

      assert ClassicPremium.queue_claimed() == 2
      assert ClassicPremium.queue_claimed() == 0

      assert %{state: "pending", classic_user_id: id, attempts: 0} =
               ClassicPremium.get(waiting.id)

      assert id == waiting.classic_user_id
      assert %{state: "pending"} = ClassicPremium.get(also_waiting.id)
      assert %{state: "ended"} = ClassicPremium.get(tried.id)
    end
  end

  describe "Retry.run_once/0" do
    defp carryover(user, state, inserted_days_ago, last_tried_at \\ nil) do
      at = days_from_now(-inserted_days_ago)

      Repo.insert!(%Carryover{
        user_id: user.id,
        classic_user_id: user.classic_user_id,
        state: state,
        inserted_at: at,
        updated_at: at,
        last_tried_at: last_tried_at
      })
    end

    test "retries young pending and every granted carry-over, then syncs stale Premium" do
      young = classic_user()
      old = classic_user()
      granted = classic_user()
      just_tried = classic_user()
      ended = classic_user()
      carryover(young, "pending", 2)
      carryover(old, "pending", 31)
      carryover(granted, "granted", 200, days_from_now(-1))
      # A redeploy hours after the last run does not ask Classic again.
      carryover(
        just_tried,
        "granted",
        200,
        DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
      )

      carryover(ended, "ended", 2)

      stale = AccountsFixtures.user_fixture()
      fresh = AccountsFixtures.user_fixture()
      premium(stale, expires_at: days_from_now(20), last_synced_at: days_from_now(-8))
      premium(fresh, expires_at: days_from_now(20), last_synced_at: days_from_now(-1))

      stub_classic(DateTime.to_iso8601(days_from_now(60)))
      fake_revenuecat()

      assert Retry.run_once() == {:ok, %{carried: 2, synced: 1}}

      looked_up =
        for _ <- 1..2 do
          assert_received {:classic_lookup, %{"id" => id}}
          String.to_integer(id)
        end

      assert Enum.sort(looked_up) == Enum.sort([young.classic_user_id, granted.classic_user_id])
      refute_received {:classic_lookup, _}

      assert %{state: "granted"} = ClassicPremium.get(young.id)
      assert %{state: "pending", last_tried_at: nil} = ClassicPremium.get(old.id)
      assert %{state: "ended", last_tried_at: nil} = ClassicPremium.get(ended.id)

      # The pass of stale entitlements reads only the stale player.
      stale_path = "/v1/subscribers/#{stale.id}"
      fresh_path = "/v1/subscribers/#{fresh.id}"
      assert_received {:revenuecat_read, ^stale_path}
      refute_received {:revenuecat_read, ^fresh_path}
      assert DateTime.after?(Entitlements.get(stale.id).last_synced_at, days_from_now(-1))
    end

    test "keeps 50 of its 200 for the stale sync, however many carry-overs wait" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      waiting =
        for _ <- 1..151 do
          user = classic_user()

          %{
            id: Ecto.UUID.generate(),
            user_id: user.id,
            classic_user_id: user.classic_user_id,
            state: "pending",
            attempts: 0,
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Carryover, waiting)
      stale = AccountsFixtures.user_fixture()
      premium(stale, expires_at: days_from_now(20), last_synced_at: days_from_now(-8))

      stub_classic({:status, 503})
      fake_revenuecat()

      {result, _log} = with_log(fn -> Retry.run_once() end)
      assert result == {:ok, %{carried: 150, synced: 1}}

      stale_path = "/v1/subscribers/#{stale.id}"
      assert_received {:revenuecat_read, ^stale_path}
    end
  end
end

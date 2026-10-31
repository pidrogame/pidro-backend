defmodule PidroServerWeb.Dev.BetaLiveTest do
  use PidroServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo
  alias PidroServer.Stats.{GameStats, SeatEvent}

  setup :register_and_log_in_admin

  setup do
    account = AccountsFixtures.user_fixture(%{email: "beta-account@example.com"})
    guest = AccountsFixtures.user_fixture(%{guest: true})

    account
    |> Ecto.Changeset.change(classic_user_id: 777, classic_claimed_at: DateTime.utc_now())
    |> Repo.update!()

    for {rule_set, ids} <- [{"louisiana", [account.id, guest.id]}, {"finnish", [guest.id]}] do
      Repo.insert!(%GameStats{
        room_code: "BETA",
        rule_set: rule_set,
        completed_at: ~U[2026-10-12 12:00:00Z],
        player_ids: ids
      })
    end

    Repo.insert!(%SeatEvent{
      user_id: guest.id,
      room_code: "BETA",
      kind: "timeout",
      elapsed_ms: 12_300,
      inserted_at: ~N[2026-10-12 12:00:00]
    })

    :ok
  end

  test "shows the report for the chosen range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/beta?from=2026-10-10&to=2026-10-16")

    assert cells(view, "beta-rules", "Louisiana: finished") == ["1", "1", "1"]
    assert cells(view, "beta-rules", "Finnish: finished") == ["0", "1", "1"]
    assert cells(view, "beta-pace", "Median time per turn") == ["–", "12.3 s", "12.3 s"]
    refute render(view) =~ "beta-account@example.com"

    view |> form("#beta-range", %{from: "2026-10-13", to: "2026-10-16"}) |> render_submit()
    assert_patch(view, ~p"/admin/beta?from=2026-10-13&to=2026-10-16")
    assert cells(view, "beta-rules", "Louisiana: finished") == ["0", "0", "0"]
  end

  test "downloads Classic ids with first-played days", %{conn: conn} do
    conn = get(conn, ~p"/admin/beta/classic.csv")

    assert response_content_type(conn, :csv)
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
    assert response(conn, 200) == "classic_user_id,first_played_on\n777,2026-10-12\n"
  end

  test "requires an admin", %{conn: _conn} do
    conn = build_conn()

    assert {:error, {:redirect, _}} = live(conn, ~p"/admin/beta")
    assert get(conn, ~p"/admin/beta/classic.csv") |> redirected_to() =~ "/admin"
  end

  # The Accounts, Guests and All cells of one row.
  defp cells(view, table, label) do
    html = view |> element("##{table} tr", label) |> render()

    Regex.scan(~r/<td[^>]*font-mono[^>]*>\s*([^<]*?)\s*<\/td>/, html, capture: :all_but_first)
    |> List.flatten()
  end
end

defmodule PidroServerWeb.Dev.GameSettingsLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.Games.{Lifecycle, PacingSettings}
  alias PidroServer.{AccountsFixtures, AdminsFixtures}
  alias PidroServer.Accounts.Token

  setup do
    original = Application.get_env(:pidro_server, Lifecycle, [])
    on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
    :ok
  end

  test "anonymous and player requests are redirected to admin login", %{conn: conn} do
    assert conn |> get(~p"/admin/game-settings") |> redirected_to() == ~p"/admin/login"
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/game-settings")

    player = AccountsFixtures.user_fixture()

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{Token.generate(player)}")

    assert conn |> get(~p"/admin/game-settings") |> redirected_to() == ~p"/admin/login"
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/game-settings")
  end

  test "temporary-password admins must change their password first", %{conn: conn} do
    admin = AdminsFixtures.admin_fixture(%{force_password_change: true})
    conn = log_in_admin(conn, admin)

    assert conn |> get(~p"/admin/game-settings") |> redirected_to() == ~p"/admin/admins"
    assert {:error, {:redirect, %{to: "/admin/admins"}}} = live(conn, ~p"/admin/game-settings")
  end

  describe "authenticated admin pacing controls" do
    setup :register_and_log_in_admin

    test "renders all settings and saves actual runtime values", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/game-settings")
      assert html =~ "Game settings"

      assert has_element?(
               view,
               "a[href='/admin/game-settings'][aria-current='page']",
               "Game settings"
             )

      values = Map.new(PacingSettings.field_specs(), &{&1.key, &1.step * 4})

      values =
        Map.merge(values, %{bot_delay_ms: 2400, bot_delay_variance_ms: 500, bot_min_delay_ms: 700})

      form_values =
        Map.new(values, fn {key, value} -> {Atom.to_string(key), to_string(value)} end)

      for {key, _value} <- form_values do
        assert has_element?(view, "input[name='pacing[#{key}]']")
      end

      view |> form("#pacing-form", pacing: form_values) |> render_change()
      assert render(view) =~ "Bots will act between 1900ms and 2900ms"
      view |> form("#pacing-form", pacing: form_values) |> render_submit()
      assert render(view) =~ "Game pacing updated"

      for {key, value} <- values, do: assert(Lifecycle.config(key) == value)

      {:ok, reloaded, _html} = live(conn, ~p"/admin/game-settings")
      assert has_element?(reloaded, "#pacing_bot_delay_ms[value='2400']")
    end

    test "rejects invalid submissions without partially saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/game-settings")
      original = PacingSettings.current_values()

      for invalid <- ["", "oops", "-1", "10001", "1.5"] do
        html =
          view
          |> form("#pacing-form",
            pacing: %{bot_delay_ms: invalid, hand_transition_delay_ms: "4100"}
          )
          |> render_submit()

        assert html =~ "Enter a value between 0ms and 10000ms"
        assert html =~ "Fix the pacing values and try again"
        assert has_element?(view, "#pacing_bot_delay_ms[value='#{invalid}']")
        assert PacingSettings.current_values() == original
      end
    end

    test "reset restores every lifecycle pacing default", %{conn: conn} do
      PacingSettings.save(Map.new(PacingSettings.field_specs(), &{&1.key, &1.max}))
      {:ok, view, _html} = live(conn, ~p"/admin/game-settings")

      view |> element("button", "Reset to Defaults") |> render_click()
      assert render(view) =~ "Game pacing reset to defaults"
      assert PacingSettings.current_values() == PacingSettings.default_values()

      for {key, value} <- PacingSettings.default_values() do
        assert has_element?(view, "#pacing_#{key}[value='#{value}']")
      end
    end
  end
end

defmodule PidroServerWeb.ResetPasswordPageControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Ecto.Query, only: [from: 2]

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  setup do
    user = AccountsFixtures.user_fixture(%{username: "aino", email: "aino@example.com"})
    {:ok, %{token: token}} = Auth.request_password_reset(user)
    %{user: user, token: token}
  end

  defp reset(conn, params), do: post(conn, ~p"/app/reset-password", params)

  defp document(conn, status), do: conn |> html_response(status) |> LazyHTML.from_document()

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp signs_in?(password), do: match?({:ok, _}, Auth.authenticate_user("aino", password))

  test "the emailed link shows the form and leaves the token alive", %{conn: conn, token: token} do
    shown = get(conn, ~p"/app/reset-password?token=#{token}")
    assert get_resp_header(shown, "cache-control") == ["no-store"]
    assert get_resp_header(shown, "referrer-policy") == ["no-referrer"]
    assert [csp] = get_resp_header(shown, "content-security-policy")
    assert csp =~ "form-action 'self'"

    page = document(shown, 200)

    assert text(page, "h1") == "Choose a new password"
    assert text(page, "label[for=password]") == "New password"
    assert page |> LazyHTML.query("input[name=token]") |> LazyHTML.attribute("value") == [token]
    assert page |> LazyHTML.query("input[name=_csrf_token]") |> Enum.count() == 1
    assert Auth.password_reset_token_live?(token)
  end

  test "a valid token sets the password and burns the token", %{conn: conn, token: token} do
    page = conn |> reset(%{"token" => token, "password" => "new password!"}) |> document(200)

    assert text(page, "h1") == "Your password is changed"
    assert text(page, ".invite-copy") == "Open Pidro and sign in."
    assert signs_in?("new password!")
    refute signs_in?("hello world!")
    refute Auth.password_reset_token_live?(token)
  end

  test "a reused token is refused and changes nothing", %{conn: conn, token: token} do
    reset(conn, %{"token" => token, "password" => "new password!"})

    page =
      build_conn() |> reset(%{"token" => token, "password" => "other password"}) |> document(404)

    assert text(page, "h1") == "This reset link is no longer valid"
    assert signs_in?("new password!")

    page = build_conn() |> get(~p"/app/reset-password?token=#{token}") |> document(404)
    assert text(page, "h1") == "This reset link is no longer valid"
  end

  test "an expired token is refused and changes nothing", %{conn: conn, user: user, token: token} do
    two_hours_ago = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [password_reset_sent_at: two_hours_ago]
    )

    assert conn |> get(~p"/app/reset-password?token=#{token}") |> document(404) |> text("h1") ==
             "This reset link is no longer valid"

    page =
      build_conn() |> reset(%{"token" => token, "password" => "new password!"}) |> document(404)

    assert text(page, "p.invite-copy") =~ "Forgot your password or name?"
    assert signs_in?("hello world!")
  end

  test "a missing, unknown or malformed token is refused", %{conn: conn, token: token} do
    assert conn |> get(~p"/app/reset-password") |> document(404) |> text("h1") ==
             "This reset link is no longer valid"

    assert build_conn() |> get(~p"/app/reset-password?token=bad") |> document(404) |> text("h1") ==
             "This reset link is no longer valid"

    assert build_conn() |> reset(%{"password" => "new password!"}) |> document(404) |> text("h1") ==
             "This reset link is no longer valid"

    for params <- [
          %{"token" => [token], "password" => "new password!"},
          %{"token" => token, "password" => ["x"]}
        ] do
      assert build_conn() |> reset(params) |> html_response(404)
    end

    assert signs_in?("hello world!")
  end

  test "a short password keeps the form and the token", %{conn: conn, token: token} do
    page = conn |> reset(%{"token" => token, "password" => "short"}) |> document(422)

    assert text(page, "[role=alert]") == "Use 8 characters or more."
    assert page |> LazyHTML.query("input[name=token]") |> LazyHTML.attribute("value") == [token]
    assert Auth.password_reset_token_live?(token)
  end

  test "Swedish when the browser asks for Swedish first", %{conn: conn, token: token} do
    swedish =
      conn
      |> put_req_header("accept-language", "sv-SE,sv;q=0.9,en;q=0.8")
      |> get(~p"/app/reset-password?token=#{token}")

    assert get_resp_header(swedish, "vary") |> Enum.join(",") =~ "Accept-Language"
    page = document(swedish, 200)
    assert text(page, "h1") == "Välj ett nytt lösenord"
    assert page |> LazyHTML.query("main") |> LazyHTML.attribute("lang") == ["sv"]

    refused =
      build_conn()
      |> put_req_header("accept-language", "fi-FI,sv;q=0.8")
      |> get(~p"/app/reset-password?token=bad")

    assert refused |> document(404) |> text("h1") == "Länken är inte längre giltig"

    english =
      build_conn()
      |> put_req_header("accept-language", "en-GB,sv;q=0.8")
      |> get(~p"/app/reset-password?token=#{token}")

    assert english |> document(200) |> text("h1") == "Choose a new password"
  end

  describe "CSRF" do
    defp with_csrf_check(conn), do: put_private(conn, :plug_skip_csrf_protection, false)

    test "the page's own form posts with its token", %{token: token} do
      shown = build_conn() |> with_csrf_check() |> get(~p"/app/reset-password?token=#{token}")

      [csrf] =
        shown
        |> document(200)
        |> LazyHTML.query("input[name=_csrf_token]")
        |> LazyHTML.attribute("value")

      done =
        shown
        |> recycle()
        |> with_csrf_check()
        |> reset(%{"_csrf_token" => csrf, "token" => token, "password" => "new password!"})

      assert done |> document(200) |> text("h1") == "Your password is changed"
      assert signs_in?("new password!")
    end

    test "a post from anywhere else is refused", %{token: token} do
      assert_error_sent 403, fn ->
        build_conn()
        |> with_csrf_check()
        |> reset(%{"token" => token, "password" => "new password!"})
      end

      assert Auth.password_reset_token_live?(token)
      assert signs_in?("hello world!")
    end
  end

  test "posts are limited per link", %{conn: conn, token: token} do
    with_limit(:password_reset_page, 1, 900_000)

    assert conn |> reset(%{"token" => token, "password" => "short"}) |> html_response(422)

    limited = build_conn() |> reset(%{"token" => token, "password" => "new password!"})
    assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(limited, 429)
    assert signs_in?("hello world!")

    # Another link has its own bucket.
    assert build_conn()
           |> reset(%{"token" => "other", "password" => "new password!"})
           |> html_response(404)
  end
end

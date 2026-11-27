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

  # The app's refusal: a notice under the same title, and a form for a new link.
  defp refused?(page) do
    text(page, "h1") == "Choose a new password" and
      text(page, ".invite-notice") == "This reset link is missing or no longer valid." and
      page
      |> LazyHTML.query(~s(form[action="/app/reset-password/link"] input[name=identifier]))
      |> Enum.count() == 1
  end

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
    assert LazyHTML.query(page, "[data-open-app]") |> Enum.empty?()
    assert page |> LazyHTML.query("[data-store]") |> Enum.count() == 2
    assert signs_in?("new password!")
    refute signs_in?("hello world!")
    refute Auth.password_reset_token_live?(token)
  end

  test "on a phone, success opens Pidro", %{conn: conn, token: token} do
    page =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)")
      |> reset(%{"token" => token, "password" => "new password!"})
      |> document(200)

    assert text(page, "[data-open-app]") == "Open Pidro"

    assert page |> LazyHTML.query("[data-open-app]") |> LazyHTML.attribute("href") ==
             ["pidro-mobile-beta://"]
  end

  test "a reused token is refused and changes nothing", %{conn: conn, token: token} do
    reset(conn, %{"token" => token, "password" => "new password!"})

    page =
      build_conn() |> reset(%{"token" => token, "password" => "other password"}) |> document(404)

    assert refused?(page)
    assert signs_in?("new password!")

    page = build_conn() |> get(~p"/app/reset-password?token=#{token}") |> document(404)
    assert refused?(page)
  end

  test "an expired token is refused and changes nothing", %{conn: conn, user: user, token: token} do
    two_hours_ago = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [password_reset_sent_at: two_hours_ago]
    )

    assert conn |> get(~p"/app/reset-password?token=#{token}") |> document(404) |> refused?()

    page =
      build_conn() |> reset(%{"token" => token, "password" => "new password!"}) |> document(404)

    assert refused?(page)
    assert signs_in?("hello world!")
  end

  test "a missing, unknown or malformed token is refused", %{conn: conn, token: token} do
    assert conn |> get(~p"/app/reset-password") |> document(404) |> refused?()

    assert build_conn() |> get(~p"/app/reset-password?token=bad") |> document(404) |> refused?()

    assert build_conn() |> reset(%{"password" => "new password!"}) |> document(404) |> refused?()

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

    assert refused |> document(404) |> text(".invite-notice") ==
             "Återställningslänken saknas eller är inte längre giltig."

    english =
      build_conn()
      |> put_req_header("accept-language", "en-GB,sv;q=0.8")
      |> get(~p"/app/reset-password?token=#{token}")

    assert english |> document(200) |> text("h1") == "Choose a new password"
  end

  describe "Send a new link" do
    defp new_link(conn, identifier),
      do: post(conn, ~p"/app/reset-password/link", %{"identifier" => identifier})

    defp await_mail do
      for pid <- Task.Supervisor.children(PidroServer.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end
    end

    defp sent?(page) do
      text(page, "h1") == "Check your email" and
        page |> LazyHTML.query("[data-state=sent] p") |> Enum.map(&LazyHTML.text/1) == [
          "If that matches a Pidro account, a link to choose a new password is on its way.",
          "The link works for one hour."
        ]
    end

    test "a known name mails a new link that works, and the old one dies", %{token: old} do
      AccountsFixtures.user_fixture(%{username: "bosse", email: "bo@example.com"})

      assert build_conn() |> new_link("aino@example.com") |> document(200) |> sent?()
      await_mail()

      assert_received {:email, %{to: [{_, "aino@example.com"}]} = email}
      refute_received {:email, _}
      [_, new] = Regex.run(~r{reset-password\?token=([A-Za-z0-9_-]+)}, email.html_body)

      refute Auth.password_reset_token_live?(old)
      page = build_conn() |> get(~p"/app/reset-password?token=#{new}") |> document(200)
      assert page |> LazyHTML.query("input[name=token]") |> LazyHTML.attribute("value") == [new]
    end

    test "an unknown name gets the same answer and no mail", %{token: token} do
      known = build_conn() |> new_link("aino") |> html_response(200)
      await_mail()
      assert_received {:email, _}

      unknown = build_conn() |> new_link("nobody-at-all") |> html_response(200)
      await_mail()
      refute_received {:email, _}

      strip = &String.replace(&1, ~r/name="_csrf_token" value="[^"]*"/, "")
      assert strip.(unknown) == strip.(known)
      refute Auth.password_reset_token_live?(token)
    end

    test "shares the API's per-address limit", %{conn: conn} do
      with_limit(:password_reset_identifier, 1, 3_600_000)

      assert conn
             |> post(~p"/api/v1/auth/password-reset", %{"identifier" => "aino"})
             |> json_response(200)

      await_mail()
      limited = build_conn() |> new_link(" AINO ")
      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(limited, 429)

      # Another address has its own bucket.
      assert build_conn() |> new_link("someone-else") |> document(200) |> sent?()
    end

    test "one client cannot spray names", %{conn: conn} do
      with_limit(:password_reset_link, 1, 900_000)

      assert conn |> from_ip({10, 2, 0, 1}) |> new_link("nobody-1") |> document(200) |> sent?()

      limited = build_conn() |> from_ip({10, 2, 0, 1}) |> new_link("aino")
      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(limited, 429)
      await_mail()
      refute_received {:email, _}

      # Another client is not held back.
      assert build_conn()
             |> from_ip({10, 2, 0, 2})
             |> new_link("nobody-2")
             |> document(200)
             |> sent?()
    end

    test "Swedish, and a missing name is refused", %{conn: conn} do
      swedish =
        conn
        |> put_req_header("accept-language", "sv-SE,sv;q=0.9")
        |> new_link("nobody-at-all")
        |> document(200)

      assert text(swedish, "h1") == "Kolla din e-post"
      assert text(swedish, "[data-state=sent]") =~ "Länken fungerar i en timme."

      assert build_conn()
             |> post(~p"/app/reset-password/link", %{})
             |> document(404)
             |> refused?()
    end
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

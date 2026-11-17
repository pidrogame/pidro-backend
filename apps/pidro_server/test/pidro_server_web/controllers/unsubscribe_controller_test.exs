defmodule PidroServerWeb.UnsubscribeControllerTest do
  use PidroServerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Swoosh.TestAssertions, only: [set_swoosh_global: 1]

  alias PidroServer.Accounts.User
  alias PidroServer.AccountsFixtures
  alias PidroServer.Emails
  alias PidroServer.Repo

  setup :set_swoosh_global

  setup do
    aino = AccountsFixtures.user_fixture(%{username: "aino", email: "aino@example.com"})
    bo = AccountsFixtures.user_fixture(%{username: "bosse", email: "bo@example.com"})
    %{aino: aino, bo: bo, path: path_for(aino)}
  end

  defp path_for(user) do
    user.id |> Emails.unsubscribe_url() |> URI.parse() |> Map.fetch!(:path)
  end

  defp one_click(path) do
    build_conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, "List-Unsubscribe=One-Click")
  end

  defp off_at(user), do: Repo.get!(User, user.id).update_emails_off_at

  test "GET shows both languages and one button, and changes nothing", %{
    conn: conn,
    aino: aino,
    path: path
  } do
    html = conn |> get(path) |> html_response(200)

    assert html =~ "Stop Pidro's update emails?"
    assert html =~ ~s(lang="sv")
    assert html =~ "Sluta få Pidros uppdateringsmejl?"
    assert html =~ "Mail you ask for, like a password reset"
    assert html =~ ~s(<form method="post" action="#{path}">)
    assert html =~ ~s(name="choice" value="off")
    refute html =~ "_csrf_token"
    assert is_nil(off_at(aino))
  end

  test "POST turns update emails off; again keeps the first time; the undo turns them on", %{
    conn: conn,
    aino: aino,
    bo: bo,
    path: path
  } do
    html = conn |> post(path, %{"choice" => "off"}) |> html_response(200)
    assert html =~ "Update emails are off"
    assert html =~ "Uppdateringsmejlen är avstängda"
    assert html =~ ~s(name="choice" value="on")
    assert %DateTime{} = first = off_at(aino)
    assert is_nil(off_at(bo))

    Repo.update_all(from(u in User, where: u.id == ^aino.id),
      set: [update_emails_off_at: ~U[2026-01-01 00:00:00Z]]
    )

    assert build_conn() |> post(path, %{"choice" => "off"}) |> html_response(200) =~
             "Update emails are off"

    assert off_at(aino) == ~U[2026-01-01 00:00:00Z]
    refute off_at(aino) == first

    # A GET after turning them off offers the way back, still changing nothing.
    assert build_conn() |> get(path) |> html_response(200) =~ "Turn them back on"
    assert off_at(aino) == ~U[2026-01-01 00:00:00Z]

    html = build_conn() |> post(path, %{"choice" => "on"}) |> html_response(200)
    assert html =~ "Update emails are on again"
    assert html =~ "Uppdateringsmejlen är på igen"
    assert is_nil(off_at(aino))

    assert build_conn() |> post(path, %{"choice" => "on"}) |> html_response(200) =~ "on again"
    assert is_nil(off_at(aino))
  end

  test "a mail app's one-click POST, without a session or CSRF token, turns them off", %{
    aino: aino,
    path: path
  } do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("accept", "*/*")
      |> post(path, "List-Unsubscribe=One-Click")

    assert conn.status == 200
    assert conn.resp_body =~ "Update emails are off"
    assert get_resp_header(conn, "set-cookie") == []
    assert %DateTime{} = off_at(aino)
  end

  test "a bad, tampered or foreign token gets the plain not-valid page and changes no one", %{
    conn: conn,
    aino: aino,
    bo: bo,
    path: path
  } do
    "/unsubscribe/" <> token = path
    # A middle character: the last one of a signature is partly padding bits.
    middle = div(String.length(token), 2)
    swapped = if String.at(token, middle) == "A", do: "B", else: "A"

    tampered =
      "/unsubscribe/" <>
        String.slice(token, 0, middle) <> swapped <> String.slice(token, (middle + 1)..-1//1)

    foreign = "/unsubscribe/" <> Phoenix.Token.sign(PidroServerWeb.Endpoint, "user socket", bo.id)

    for bad <- ["/unsubscribe/sample-only", tampered, foreign] do
      html = conn |> get(bad) |> html_response(404)
      assert html =~ "This link is not valid"
      assert html =~ "Den här länken är inte giltig"
      refute html =~ "<form"

      assert one_click(bad) |> html_response(404) =~
               "This link is not valid"
    end

    assert is_nil(off_at(aino))
    assert is_nil(off_at(bo))

    # Aino's link turns off Aino alone.
    build_conn() |> post(path, %{"choice" => "off"})
    assert %DateTime{} = off_at(aino)
    assert is_nil(off_at(bo))
  end

  test "an opted-out player still gets a password-reset mail", %{aino: aino, path: path} do
    one_click(path)
    assert %DateTime{} = off_at(aino)

    assert build_conn()
           |> post(~p"/api/v1/auth/password-reset", %{"identifier" => "aino"})
           |> json_response(200)

    # The mail leaves after the response, from the task supervisor.
    assert_receive {:email, email}
    assert email.to == [{"aino", "aino@example.com"}]
    assert email.text_body =~ "/reset-password?token="
  end
end

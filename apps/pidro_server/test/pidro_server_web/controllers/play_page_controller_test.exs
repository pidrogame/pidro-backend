defmodule PidroServerWeb.PlayPageControllerTest do
  use PidroServerWeb.ConnCase, async: true

  alias PidroServer.AccountsFixtures

  describe "GET /play/:slug" do
    test "names a known player with share metadata and an app handoff", %{conn: conn} do
      AccountsFixtures.user_fixture(%{username: "Bengt Åberg", display_name: "Bengt"})

      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)")
        |> get(~p"/play/bengt-aberg")

      document = conn |> html_response(200) |> LazyHTML.from_document()
      canonical = "http://localhost:4002/play/bengt-aberg"

      assert text(document, "h1") == "Play Pidro with Bengt"
      assert text(document, "title") == "Play Pidro with Bengt"

      assert attribute(document, "meta[property='og:title']", "content") ==
               "Play Pidro with Bengt"

      assert attribute(document, "meta[property='og:url']", "content") == canonical
      assert attribute(document, "meta[property='og:image']", "content") =~ "/images/invite/"
      assert attribute(document, "link[rel=canonical]", "href") == canonical
      assert LazyHTML.query(document, "meta[name=apple-itunes-app]") |> Enum.empty?()

      assert attribute(document, "[data-primary-action]", "href") ==
               "pidro-mobile-beta://play/bengt-aberg"

      assert text(document, "[data-player-avatar]") == "B"
      assert store_links(document) == ["apple", "google"]

      assert attribute(document, "[data-store=apple]", "data-deferred-capture") ==
               "http://localhost:4002/play/bengt-aberg/deferred"

      assert attribute(document, "[data-store=apple]", "data-deferred-platform") == "ios"

      assert attribute(document, "[data-store=apple]", "href") ==
               "https://testflight.apple.com/join/2JR95b65"

      assert attribute(document, "[data-store=google]", "href") ==
               "https://play.google.com/store/apps/details?id=com.oneapps.pidro.beta&referrer=friend%3Dbengt-aberg"

      assert text(document, "[data-install-note]") == "Installed it? Tap this link again."
      assert attribute(document, "script", "src") =~ "/assets/js/invite.js"
      assert text(document, ".invite-privacy-note") =~ "30 minutes"

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      assert csp =~ "connect-src http://localhost:4002"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "Android captures only its store badge and desktop captures neither", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      android =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (Linux; Android 15)")
        |> get(~p"/play/#{user.share_slug}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert attribute(android, "[data-store=google]", "data-deferred-platform") == "android"

      assert attribute(android, "[data-store=google]", "data-deferred-capture") =~
               "/play/#{user.share_slug}/deferred"

      assert LazyHTML.query(android, "[data-store=apple][data-deferred-capture]") |> Enum.empty?()

      desktop =
        build_conn()
        |> put_req_header("user-agent", "Mozilla/5.0 (X11; Linux x86_64)")
        |> get(~p"/play/#{user.share_slug}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert LazyHTML.query(desktop, "[data-deferred-capture]") |> Enum.empty?()
    end

    test "an unknown slug renders the page without a name or handoff", %{conn: conn} do
      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (Linux; Android 15)")
        |> get(~p"/play/nobody-here")

      html = html_response(conn, 404)
      document = LazyHTML.from_document(html)

      assert text(document, "h1") == "Play Pidro"
      assert attribute(document, "meta[property='og:title']", "content") == "Play Pidro"
      refute html =~ "nobody-here"

      assert LazyHTML.query(document, "[data-deferred-capture], script, .invite-privacy-note")
             |> Enum.empty?()

      assert LazyHTML.query(document, "[data-primary-action]") |> Enum.empty?()
      assert LazyHTML.query(document, "link[rel=canonical]") |> Enum.empty?()
      assert LazyHTML.query(document, "[data-install-note]") |> Enum.empty?()
      assert store_links(document) == ["apple", "google"]
    end
  end

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attribute(document, selector, name) do
    [value] = document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
    value
  end

  defp store_links(document),
    do: document |> LazyHTML.query("[data-store]") |> LazyHTML.attribute("data-store")
end

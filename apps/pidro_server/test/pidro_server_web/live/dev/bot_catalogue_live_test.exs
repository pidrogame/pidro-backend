defmodule PidroServerWeb.Dev.BotCatalogueLiveTest do
  use PidroServerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias PidroServer.{BotCatalogue, Repo}
  alias PidroServer.BotCatalogue.Profile
  alias PidroServer.GameArchive.Archive
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.RoomManager

  setup do
    original = BotCatalogue.profiles()
    BotCatalogue.refresh()

    on_exit(fn ->
      :persistent_term.put(BotCatalogue, original)
    end)

    :ok
  end

  test "requires admin auth and revalidates a revoked session", %{conn: conn} do
    assert conn |> get(~p"/admin/bots") |> redirected_to() == "/admin/login"
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    token = get_session(conn, :admin_token)
    PidroServer.Admins.delete_admin_session_token(token)
    render_click(view, "new")
    assert_redirect(view, "/admin/login")
    assert Repo.aggregate(Profile, :count) == 3
  end

  test "seeded faces, create fourth identity, edit/disable and public allowlist", %{conn: conn} do
    %{conn: admin_conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, html} = live(admin_conn, ~p"/admin/bots")
    for id <- ~w(marcel antti jocke), do: assert(html =~ "/images/bots/#{id}.svg")

    users_before = Repo.aggregate(PidroServer.Accounts.User, :count)
    view |> element("#add-bot") |> render_click()

    view
    |> form("#bot-form",
      bot: %{
        name: "Fourth",
        description: "Public biography",
        portrait: "jocke",
        strategy: "random",
        tempo: "slow",
        enabled: true
      }
    )
    |> render_submit()

    fourth = Repo.get_by!(Profile, name: "Fourth")
    assert fourth.tempo == "slow"
    assert has_element?(view, "#bot-#{fourth.id} .bot-meta", "anywhere · slow · random")
    assert {:ok, _} = Ecto.UUID.cast(fourth.id)
    assert Repo.aggregate(PidroServer.Accounts.User, :count) == users_before
    refute Repo.get_by(PidroServer.Profiles.PlayerProfile, user_id: fourth.id)
    view |> element("#bot-#{fourth.id} button") |> render_click()
    view |> form("#bot-form", bot: %{name: "Fourth edited", enabled: false}) |> render_submit()
    assert Repo.get!(Profile, fourth.id).name == "Fourth edited"
    refute Repo.get!(Profile, fourth.id).enabled
    assert fourth.id not in Enum.map(BotCatalogue.available(), & &1.id)

    data = conn |> get(~p"/api/v1/bots") |> json_response(200) |> Map.fetch!("data")
    public = Enum.find(data, &(&1["id"] == fourth.id))
    assert public["name"] == "Fourth edited"
    assert public["avatar_url"] =~ "/images/bots/jocke.svg"
    assert public["tempo"] == "slow"
    assert public["strategy"] == "random"

    assert Enum.sort(Map.keys(public)) ==
             ~w(appetite avatar_url description home id lines name strategy tempo voice)
  end

  test "a new bot is steady, and the tempo only takes quick, steady or slow", %{conn: conn} do
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    view |> element("#add-bot") |> render_click()
    assert has_element?(view, "#bot-form select[name='bot[tempo]'] option[selected]", "Steady")

    view |> element("#bot-antti button") |> render_click()
    html = render_change(view, "validate", %{"bot" => %{"id" => "antti", "tempo" => "frantic"}})
    assert html =~ "is invalid"
    html = render_submit(view, "save", %{"bot" => %{"id" => "antti", "tempo" => "frantic"}})
    assert html =~ "is invalid"
    assert BotCatalogue.get!("antti").tempo == "slow"

    view |> form("#bot-form", bot: %{tempo: "quick"}) |> render_submit()
    assert BotCatalogue.get!("antti").tempo == "quick"
    assert BotCatalogue.profile("antti").tempo == "quick"

    assert_raise Postgrex.Error, ~r/supported_tempo/, fn ->
      Repo.update_all(Profile, set: [tempo: "frantic"])
    end
  end

  test "the form saves a home and lines, one per line, and the card shows them", %{conn: conn} do
    %{conn: admin_conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(admin_conn, ~p"/admin/bots")
    view |> element("#add-bot") |> render_click()
    assert has_element?(view, "#bot-form select[name='bot[home]'] option[selected]", "Anywhere")
    assert has_element?(view, "#bot-antti .bot-meta", "anywhere · slow")
    refute has_element?(view, "#bot-antti li")

    view |> element("#bot-antti button") |> render_click()

    view
    |> form("#bot-form",
      bot: %{home: "louisiana", lines: "Hmm, jaha…\n\n  Let's see…  \r\nVäntä lite…\n"}
    )
    |> render_submit()

    assert %{home: "louisiana", lines: ["Hmm, jaha…", "Let's see…", "Väntä lite…"]} =
             BotCatalogue.get!("antti")

    assert has_element?(view, "#bot-antti .bot-meta", "Louisiana · slow")

    assert ["Hmm, jaha…", "Let's see…", "Väntä lite…"] ==
             view |> element("#bot-antti ul") |> render() |> texts("li")

    view |> element("#bot-antti button") |> render_click()

    assert view |> element("#bot-form textarea[name='bot[lines]']") |> render() =~
             "Hmm, jaha…\nLet&#39;s see…\nVäntä lite…"

    nine = Enum.map_join(1..9, "\n", &"Line #{&1}")
    html = view |> form("#bot-form", bot: %{lines: nine}) |> render_submit()
    assert html =~ "should have at most 8 item(s)"
    assert view |> element("#bot-form textarea[name='bot[lines]']") |> render() =~ "Line 9"
    assert BotCatalogue.get!("antti").lines == ["Hmm, jaha…", "Let's see…", "Väntä lite…"]

    data = conn |> get(~p"/api/v1/bots") |> json_response(200) |> Map.fetch!("data")

    assert %{"home" => "louisiana", "lines" => ["Hmm, jaha…", "Let's see…", "Väntä lite…"]} =
             Enum.find(data, &(&1["id"] == "antti"))
  end

  test "the strategy select offers search, and the form saves it", %{conn: conn} do
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    view |> element("#bot-jocke button") |> render_click()

    assert has_element?(
             view,
             "#bot-form select[name='bot[strategy]'] option[value='search']",
             "Search (plays the odds)"
           )

    view |> form("#bot-form", bot: %{strategy: "rulebook"}) |> render_submit()
    assert BotCatalogue.get!("jocke").strategy == "rulebook"
    assert has_element?(view, "#bot-jocke .bot-meta", "steady · plays the honest game")

    view |> element("#bot-jocke button") |> render_click()
    view |> form("#bot-form", bot: %{strategy: "search"}) |> render_submit()
    assert BotCatalogue.get!("jocke").strategy == "search"
    assert BotCatalogue.profile("jocke").strategy == "search"
    assert has_element?(view, "#bot-jocke .bot-meta", "steady · plays the odds")
  end

  test "a delayed form from the previous selection cannot overwrite another bot", %{conn: conn} do
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    view |> element("#bot-marcel button") |> render_click()
    view |> element("#bot-antti button") |> render_click()
    html = render_submit(view, "save", %{"bot" => %{"id" => "marcel", "name" => "Wrong profile"}})
    assert html =~ "Selection changed"
    assert BotCatalogue.get!("antti").name == "Antti"
    assert BotCatalogue.get!("marcel").name == "Marcel"
  end

  test "rejects strategy/module injection and untrusted portrait URLs", %{conn: conn} do
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")

    view |> element("#bot-marcel button") |> render_click()

    html =
      render_submit(view, "save", %{
        "bot" => %{
          "name" => "Bad",
          "strategy" => "Elixir.System",
          "portrait" => "https://attacker/image.svg",
          "id" => "marcel"
        }
      })

    assert html =~ "is invalid"
    refute Repo.get_by(Profile, name: "Bad")
  end

  test "normalizes uploaded PNG, serves safe JPEG, rejects disguised SVG and oversized upload", %{
    conn: conn
  } do
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    view |> element("#add-bot") |> render_click()
    dir = Path.join(System.tmp_dir!(), "bot-upload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    png = Path.join(dir, "portrait.png")
    {_, 0} = System.cmd("convert", ["-size", "40x60", "xc:blue", png])

    upload =
      file_input(view, "#bot-form", :avatar, [
        %{name: "portrait.png", content: File.read!(png), type: "image/png"}
      ])

    render_upload(upload, "portrait.png")
    # A rejected form must retain the already validated upload for correction.
    html = render_submit(view, "save", %{"bot" => %{"name" => String.duplicate("x", 61)}})
    assert html =~ "should be at most 60 character"
    refute Repo.get_by(Profile, name: "Upload bot")
    view |> form("#bot-form", bot: %{name: "Upload bot"}) |> render_submit()
    profile = Repo.get_by!(Profile, name: "Upload bot")
    assert profile.portrait == "upload"
    assert <<0xFF, 0xD8, 0xFF, _::binary>> = profile.image
    image_conn = build_conn() |> get("/api/v1/bots/#{profile.id}/avatar/#{profile.image_version}")
    assert response(image_conn, 200) == profile.image
    assert get_resp_header(image_conn, "content-type") == ["image/jpeg"]
    assert build_conn() |> get("/api/v1/bots/#{profile.id}/avatar/wrong") |> response(404) == ""
    refute has_element?(view, "#bot-form")
    assert has_element?(view, "#bot-#{profile.id} img[src$='/avatar/#{profile.image_version}']")
    view |> element("#bot-#{profile.id} button") |> render_click()

    svg =
      file_input(view, "#bot-form", :avatar, [
        %{
          name: "disguised.png",
          content: "<svg><script>alert(1)</script></svg>",
          type: "image/png"
        }
      ])

    render_upload(svg, "disguised.png")
    html = view |> form("#bot-form", bot: %{name: "Must not save"}) |> render_submit()
    assert html =~ "Invalid image"
    assert Repo.get!(Profile, profile.id).name == "Upload bot"

    oversized =
      file_input(view, "#bot-form", :avatar, [
        %{name: "huge.png", content: String.duplicate("x", 5_242_881), type: "image/png"}
      ])

    assert {:error, [[_, :too_large]]} = render_upload(oversized, "huge.png")
  end

  defp crew! do
    for attrs <- [
          %{
            name: "Aino",
            home: "finland",
            strategy: "search",
            tempo: "slow",
            voice: "teasing",
            appetite: "chatty"
          },
          %{
            name: "Eero",
            home: "finland",
            strategy: "rulebook",
            lines: ["Hmm, jaha…", "No niin"]
          },
          %{name: "Boudreaux", home: "louisiana", strategy: "random", tempo: "quick"},
          %{name: "Clotile", home: "louisiana", strategy: "search", enabled: false}
        ],
        into: %{} do
      {:ok, profile} = BotCatalogue.save(BotCatalogue.new(), attrs)
      {profile.name, profile}
    end
  end

  defp texts(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp rows(view), do: view |> render() |> texts("#bot-roster > article h3")

  defp counts(view) do
    labels = view |> element("#bot-counts") |> render() |> texts("dt")
    values = view |> element("#bot-counts") |> render() |> texts("dd")
    Map.new(Enum.zip(labels, Enum.map(values, &String.to_integer/1)))
  end

  defp facts(view, id) do
    html = view |> element("#bot-#{id} .bot-facts") |> render()
    Enum.zip(texts(html, "dt"), texts(html, "dd"))
  end

  test "a new bot is dry and normal; voice and appetite take only their values, and filter",
       %{conn: conn} do
    crew = crew!()
    %{conn: admin_conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(admin_conn, ~p"/admin/bots")
    view |> element("#add-bot") |> render_click()
    assert has_element?(view, "#bot-form select[name='bot[voice]'] option[selected]", "Dry")
    assert has_element?(view, "#bot-form select[name='bot[appetite]'] option[selected]", "Normal")

    view |> element("#bot-jocke button") |> render_click()

    for bad <- [%{"voice" => "shouty"}, %{"appetite" => "never"}, %{"voice" => ""}] do
      html = render_submit(view, "save", %{"bot" => Map.put(bad, "id", "jocke")})
      assert html =~ "is invalid" or html =~ "can&#39;t be blank"
    end

    assert %{voice: "dry", appetite: "normal"} = BotCatalogue.get!("jocke")

    view |> form("#bot-form", bot: %{voice: "warm", appetite: "chatty"}) |> render_submit()
    assert %{voice: "warm", appetite: "chatty"} = BotCatalogue.get!("jocke")
    assert %{voice: "warm", appetite: "chatty"} = BotCatalogue.profile("jocke")
    assert has_element?(view, "#bot-jocke .bot-meta", "warm, chatty")

    data = conn |> get(~p"/api/v1/bots") |> json_response(200) |> Map.fetch!("data")
    assert %{"voice" => "warm", "appetite" => "chatty"} = Enum.find(data, &(&1["id"] == "jocke"))

    {:ok, view, _} = live(admin_conn, ~p"/admin/bots?voice=teasing")
    assert rows(view) |> Enum.sort() == Enum.sort(["Aino", "Antti"])
    assert crew["Aino"].voice == "teasing"

    assert_raise Postgrex.Error, ~r/supported_voice/, fn ->
      Repo.update_all(Profile, set: [voice: "shouty"])
    end
  end

  test "the roster shows every character with its meta line and lines, and counts them",
       %{conn: conn} do
    crew = crew!()
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")

    assert Enum.sort(rows(view)) == Enum.sort(Enum.map(BotCatalogue.list(), & &1.name))

    for {name, meta} <- [
          {"Aino", "Finland · slow · plays the odds · teasing, chatty"},
          {"Eero", "Finland · steady · plays the honest game · dry, normal"},
          {"Boudreaux", "Louisiana · quick · random · dry, normal"},
          {"Clotile", "Louisiana · steady · plays the odds · dry, normal"}
        ] do
      assert [^meta] = view |> element("#bot-#{crew[name].id}") |> render() |> texts(".bot-meta")
    end

    assert ["Hmm, jaha…", "No niin"] ==
             view |> element("#bot-#{crew["Eero"].id}") |> render() |> texts("ul li")

    assert has_element?(view, "#bot-#{crew["Clotile"].id}.opacity-60", "Disabled")
    refute has_element?(view, "#bot-#{crew["Aino"].id}", "Disabled")
    refute has_element?(view, "#bot-#{crew["Aino"].id}.opacity-60")

    profiles = BotCatalogue.list()
    counts = counts(view)
    assert counts["Characters"] == length(rows(view))
    assert counts["Play the odds"] == Enum.count(profiles, &(&1.strategy == "search"))
    assert counts["Disabled"] == 1

    for {home, label} <- [
          {"finland", "Finland"},
          {"louisiana", "Louisiana"},
          {"anywhere", "Anywhere"}
        ] do
      {:ok, filtered, _} = live(conn, ~p"/admin/bots?home=#{home}")
      assert length(rows(filtered)) == counts[label]
    end

    {:ok, odds, _} = live(conn, ~p"/admin/bots?strategy=search")
    assert length(rows(odds)) == counts["Play the odds"]
    assert counts["Finland"] == 2 and counts["Louisiana"] == 2
  end

  test "each filter narrows the rows and writes itself into the URL", %{conn: conn} do
    crew!()
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")

    view |> element("#bot-filters a", "Louisiana") |> render_click()
    assert_patch(view, "/admin/bots?home=louisiana")
    assert Enum.sort(rows(view)) == ["Boudreaux", "Clotile"]

    view |> element("#bot-filters a", "Plays the odds") |> render_click()
    assert_patch(view, "/admin/bots?home=louisiana&strategy=search")
    assert rows(view) == ["Clotile"]

    view |> element("#bot-filters a", "Enabled only") |> render_click()
    assert_patch(view, "/admin/bots?enabled=1&home=louisiana&strategy=search")
    assert rows(view) == []
    assert render(view) =~ "No character matches these filters."

    view |> element("#bot-filters a", "Random") |> render_click()
    assert_patch(view, "/admin/bots?enabled=1&home=louisiana&strategy=random")
    assert rows(view) == ["Boudreaux"]

    {:ok, shared, _} = live(conn, ~p"/admin/bots?home=finland&strategy=bogus")
    assert Enum.sort(rows(shared)) == ["Aino", "Eero"]
    assert has_element?(shared, "#bot-filters a[aria-current]", "Finland")
  end

  test "a card opens the form prefilled in a panel, and saving closes it and updates the card",
       %{conn: conn} do
    %{"Eero" => eero} = crew!()
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    refute has_element?(view, "#bot-form")

    view |> element("#bot-#{eero.id}") |> render_click()

    assert has_element?(
             view,
             "#bot-editor-#{eero.id} #bot-form input[name='bot[name]'][value='Eero']"
           )

    assert has_element?(view, "#bot-form select[name='bot[home]'] option[selected]", "Finland")

    assert view |> element("#bot-form textarea[name='bot[lines]']") |> render() =~
             "Hmm, jaha…\nNo niin"

    html =
      view |> form("#bot-form", bot: %{name: "Eero Junior", tempo: "quick"}) |> render_submit()

    assert html =~ "Strategy applies to newly seated bots"
    refute has_element?(view, "#bot-form")
    assert has_element?(view, "#bot-#{eero.id} h3", "Eero Junior")

    assert has_element?(
             view,
             "#bot-#{eero.id} .bot-meta",
             "Finland · quick · plays the honest game"
           )

    view |> element("#bot-#{eero.id} button") |> render_click()
    render_change(view, "validate", %{"bot" => %{"id" => eero.id, "name" => "Half typed"}})
    view |> element("#bot-#{eero.id}") |> render_click()
    assert has_element?(view, "#bot-form input[name='bot[name]'][value='Half typed']")
    view |> element("#bot-editor-#{eero.id} button", "Close") |> render_click()
    refute has_element?(view, "#bot-form")
    html = render_submit(view, "save", %{"bot" => %{"id" => eero.id, "name" => "Stale"}})
    assert html =~ "Selection changed"
    assert BotCatalogue.get!(eero.id).name == "Eero Junior"
  end

  test "facts say not recorded when the archive names no persona", %{conn: conn} do
    %{"Aino" => aino} = crew!()
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")

    assert facts(view, aino.id) == [
             {"Seated now", "0"},
             {"Past 7 days", "not recorded"},
             {"All games", "not recorded"},
             {"Won", "not recorded"}
           ]
  end

  test "facts count live seats and archived games and wins per persona", %{conn: conn} do
    %{"Aino" => aino} = crew!()
    now = DateTime.utc_now()

    archive! = fn seats, winner, days_ago ->
      at = DateTime.add(now, -days_ago * 86_400)

      Repo.insert!(%Archive{
        game_instance_id: Ecto.UUID.generate(),
        room_code: "FACTS",
        format_version: 1,
        versions: %{},
        participants:
          Map.new(seats, fn
            {position, nil} ->
              {position, %{"occupant_type" => "bot", "bot_persona" => nil}}

            {position, :human} ->
              {position, %{"occupant_type" => "human", "user_id" => "u"}}

            {position, persona} ->
              {position, %{"occupant_type" => "bot", "bot_persona" => persona}}
          end),
        status: if(winner, do: "complete", else: "closed"),
        evidence_status: "continuous",
        last_revision: 1,
        initial_snapshot: %{},
        last_snapshot: %{"state" => %{"winner" => winner}},
        started_at: at,
        saved_at: at
      })
    end

    # This week Aino wins at east, loses at west and wins at north; an older game had no winner.
    archive!.(%{"north" => :human, "east" => aino.id, "west" => "antti"}, "east_west", 1)
    archive!.(%{"north" => :human, "west" => aino.id}, "north_south", 2)
    archive!.(%{"north" => aino.id}, "north_south", 3)
    archive!.(%{"east" => aino.id}, nil, 10)
    # Jocke on both teams of a decided game played it but has no side in it.
    archive!.(%{"north" => :human, "east" => "jocke", "south" => "jocke"}, "east_west", 4)
    # A bot seat from before personas were archived counts for nobody.
    archive!.(%{"east" => nil}, "east_west", 20)

    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _ -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    host = PidroServer.AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{solo: true})

    for pos <- [:east, :south, :west],
        do: {:ok, _} = BotManager.start_bot(room.code, pos, :basic, 5_000)

    {:ok, room} = RoomManager.get_room(room.code)
    seated = for {_, %{bot_persona: persona}} <- room.seats, is_binary(persona), do: persona
    assert length(seated) == 3

    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    since = "Since " <> Calendar.strftime(DateTime.add(now, -10 * 86_400), "%-d %b")

    for profile <- BotCatalogue.list(), profile.enabled do
      [{"Seated now", count} | _] = facts(view, profile.id)
      assert count == if(profile.id in seated, do: "1", else: "0")
    end

    assert facts(view, aino.id) |> tl() ==
             [{"Past 7 days", "3"}, {since, "4"}, {"Won", "67% of 3"}]

    assert facts(view, "antti") |> tl() ==
             [{"Past 7 days", "1"}, {since, "1"}, {"Won", "100% of 1"}]

    assert facts(view, "jocke") |> tl() ==
             [{"Past 7 days", "1"}, {since, "1"}, {"Won", "not recorded"}]
  end
end

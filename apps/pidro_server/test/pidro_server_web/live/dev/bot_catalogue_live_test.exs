defmodule PidroServerWeb.Dev.BotCatalogueLiveTest do
  use PidroServerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias PidroServer.{BotCatalogue, Repo}
  alias PidroServer.BotCatalogue.Profile

  setup do
    BotCatalogue.refresh()

    on_exit(fn ->
      :persistent_term.put(BotCatalogue, BotCatalogue.defaults())
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
    assert render(view) =~ "random · slow"
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
    assert Enum.sort(Map.keys(public)) == ~w(avatar_url description id name tempo)
  end

  test "a new bot is steady, and the tempo only takes quick, steady or slow", %{conn: conn} do
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, view, _} = live(conn, ~p"/admin/bots")
    assert has_element?(view, "#bot-form select[name='bot[tempo]'] option[selected]", "Steady")

    view |> element("#bot-antti button") |> render_click()
    html = render_change(view, "validate", %{"bot" => %{"id" => "antti", "tempo" => "frantic"}})
    assert html =~ "is invalid"
    html = render_submit(view, "save", %{"bot" => %{"id" => "antti", "tempo" => "frantic"}})
    assert html =~ "is invalid"
    assert BotCatalogue.get!("antti").tempo == "steady"

    view |> form("#bot-form", bot: %{tempo: "quick"}) |> render_submit()
    assert BotCatalogue.get!("antti").tempo == "quick"
    assert BotCatalogue.profile("antti").tempo == "quick"

    assert_raise Postgrex.Error, ~r/supported_tempo/, fn ->
      Repo.update_all(Profile, set: [tempo: "frantic"])
    end
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
end

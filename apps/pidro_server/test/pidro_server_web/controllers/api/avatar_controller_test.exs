defmodule PidroServerWeb.API.AvatarControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.{Avatars, Token, UserAvatar}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "avatar-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "upload requires authentication and only changes the authenticated user's avatar", %{
    conn: conn,
    dir: dir
  } do
    owner = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()
    image = png!(dir, "owner.png")

    assert conn
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(image)})
           |> json_response(401)

    conn = conn |> auth(owner) |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(image)})
    assert %{"data" => %{"avatar_url" => url}} = json_response(conn, 200)
    assert String.starts_with?(url, PidroServerWeb.Endpoint.url())
    assert Avatars.metadata_for(owner.id)
    refute Avatars.metadata_for(other.id)
  end

  test "invalid and oversized replacement preserve the old row", %{conn: conn, dir: dir} do
    user = AccountsFixtures.user_fixture()
    valid = png!(dir, "valid.png")

    assert conn
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(valid)})
           |> response(200)

    old = Repo.get!(UserAvatar, user.id)

    invalid = Path.join(dir, "invalid.png")
    File.write!(invalid, "not an image")

    invalid_response =
      build_conn()
      |> auth(user)
      |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(invalid)})
      |> json_response(422)

    assert invalid_response ==
             avatar_error(
               "avatar_unsupported_type",
               "unsupported avatar type; upload JPEG or PNG"
             )

    assert Repo.get!(UserAvatar, user.id).version == old.version

    oversized = Path.join(dir, "oversized.png")
    File.write!(oversized, <<0x89, "PNG\r\n", 0x1A, 0x0A, 0::size(5_242_881 * 8)>>)

    oversized_response =
      build_conn()
      |> auth(user)
      |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(oversized)})
      |> json_response(422)

    assert oversized_response == avatar_error("avatar_too_large", "avatar must be at most 5 MiB")

    assert Repo.get!(UserAvatar, user.id).version == old.version
  end

  test "missing avatar has a field-required contract and keeps its English error", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    conn = conn |> auth(user) |> post(~p"/api/v1/profile/avatar", %{})

    assert json_response(conn, 422) ==
             avatar_error("field_required", "multipart field avatar is required")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "corrupt supported images use avatar_invalid", %{conn: conn, dir: dir} do
    user = AccountsFixtures.user_fixture()
    corrupt = Path.join(dir, "corrupt.png")
    File.write!(corrupt, <<0x89, "PNG\r\n", 0x1A, 0x0A, "corrupt">>)

    assert conn
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(corrupt)})
           |> json_response(422) == avatar_error("avatar_invalid", "invalid avatar image")
  end

  test "remove deletes the row", %{conn: conn, dir: dir} do
    user = AccountsFixtures.user_fixture()

    assert conn
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(png!(dir, "remove.png"))})
           |> response(200)

    assert build_conn() |> auth(user) |> delete(~p"/api/v1/profile/avatar") |> json_response(200) ==
             %{"data" => %{"avatar_url" => nil}}

    refute Repo.get(UserAvatar, user.id)
  end

  test "public immutable URL serves exact version without JSON Accept and malformed UUID is 404",
       %{
         conn: conn,
         dir: dir
       } do
    user = AccountsFixtures.user_fixture()

    assert conn
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(png!(dir, "public.png"))})
           |> response(200)

    avatar = Repo.get!(UserAvatar, user.id)

    served =
      build_conn()
      |> put_req_header("accept", "image/*")
      |> get("/api/v1/users/#{user.id}/avatar/#{avatar.version}")

    assert response(served, 200) == avatar.image
    assert get(build_conn(), "/api/v1/users/#{user.id}/avatar/wrong").status == 404
    assert get(build_conn(), "/api/v1/users/not-a-uuid/avatar/#{avatar.version}").status == 404
  end

  test "normalizes orientation and metadata and flattens PNG transparency", %{dir: dir} do
    user = AccountsFixtures.user_fixture()
    source = Path.join(dir, "oriented.jpg")

    {_, 0} =
      System.cmd("convert", [
        "-size",
        "80x40",
        "xc:red",
        "-fill",
        "blue",
        "-draw",
        "rectangle 40,0 79,39",
        "-set",
        "comment",
        "secret",
        "JPEG:#{source}"
      ])

    # Real EXIF APP1 orientation=6, not ImageMagick's transient orientation setting.
    exif =
      <<"Exif", 0, 0, "II", 42::little-16, 8::little-32, 1::little-16, 0x0112::little-16,
        3::little-16, 1::little-32, 6::little-16, 0::16, 0::32>>

    <<0xFF, 0xD8, rest::binary>> = File.read!(source)

    File.write!(
      source,
      <<0xFF, 0xD8, 0xFF, 0xE1, byte_size(exif) + 2::16, exif::binary, rest::binary>>
    )

    assert {"RightTop", 0} = System.cmd("identify", ["-format", "%[orientation]", source])

    assert {:ok, _url} = Avatars.put(user.id, upload(source))
    output = Repo.get!(UserAvatar, user.id).image
    normalized = Path.join(dir, "normalized.jpg")
    File.write!(normalized, output)
    assert {"256 256", 0} = System.cmd("identify", ["-format", "%w %h", "JPEG:#{normalized}"])
    assert {"", 0} = System.cmd("identify", ["-format", "%c", "JPEG:#{normalized}"])
    refute output =~ "Exif"

    assert {"1 1", 0} =
             System.cmd("convert", [
               normalized,
               "-format",
               "%[fx:p{128,32}.r>0.9] %[fx:p{128,224}.b>0.9]",
               "info:"
             ])

    transparent = png!(dir, "transparent.png", "none")
    assert {:ok, _url} = Avatars.put(user.id, upload(transparent))
    File.write!(normalized, Repo.get!(UserAvatar, user.id).image)

    assert {"1 1 1", 0} =
             System.cmd("convert", [
               "JPEG:#{normalized}",
               "-format",
               "%[fx:p{0,0}.r>0.99] %[fx:p{0,0}.g>0.99] %[fx:p{0,0}.b>0.99]",
               "info:"
             ])
  end

  test "deleting a user cascades its avatar", %{dir: dir} do
    user = AccountsFixtures.user_fixture()
    assert {:ok, _url} = Avatars.put(user.id, upload(png!(dir, "cascade.png")))
    Repo.delete!(user)
    refute Repo.get(UserAvatar, user.id)
  end

  test "busy processing preserves the previous image and gives a retryable result", %{dir: dir} do
    user = AccountsFixtures.user_fixture()
    image = png!(dir, "busy.png")
    assert {:ok, _} = Avatars.put(user.id, upload(image))
    previous = Repo.get!(UserAvatar, user.id)
    # Hold the resource as a different requester to simulate another active conversion.
    lock = {Avatars, make_ref()}
    assert :global.set_lock(lock, [node()], 0)

    try do
      assert {:error, :busy} = Avatars.put(user.id, upload(image))

      assert build_conn()
             |> auth(user)
             |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(image)})
             |> json_response(503) ==
               avatar_error("avatar_busy", "photo processing is busy; please try again")

      assert Repo.get!(UserAvatar, user.id).image == previous.image
    after
      :global.del_lock(lock, [node()])
    end
  end

  describe "PUT /api/v1/profile/avatar/face (PID-395)" do
    test "a registered player picks a face and gets the current user back", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      face_b = face_url("b")

      response =
        conn
        |> auth(user)
        |> put(~p"/api/v1/profile/avatar/face", %{"face" => "b"})
        |> json_response(200)

      assert %{"avatar_face" => "b", "has_photo" => false, "avatar_url" => ^face_b} =
               response["data"]["user"]

      assert response["data"]["user"]["id"] == user.id
      assert_schema(response, "User Response")

      me = build_conn() |> auth(user) |> get(~p"/api/v1/auth/me") |> json_response(200)

      assert %{"avatar_face" => "b", "has_photo" => false, "avatar_url" => ^face_b} =
               me["data"]["user"]
    end

    test "a guest may pick a face", %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()

      assert %{"data" => %{"user" => %{"guest" => true, "avatar_face" => "a"} = user}} =
               conn
               |> auth(guest)
               |> put(~p"/api/v1/profile/avatar/face", %{"face" => "a"})
               |> json_response(200)

      assert user["avatar_url"] == face_url("a")
    end

    test "any other face is a 422 and changes nothing", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      for body <- [%{"face" => "c"}, %{"face" => nil}, %{}] do
        assert build_conn()
               |> auth(user)
               |> put(~p"/api/v1/profile/avatar/face", body)
               |> json_response(422)
      end

      assert conn
             |> auth(user)
             |> get(~p"/api/v1/auth/me")
             |> json_response(200)
             |> get_in(["data", "user", "avatar_face"]) == nil
    end

    test "needs a token", %{conn: conn} do
      assert conn |> put(~p"/api/v1/profile/avatar/face", %{"face" => "b"}) |> json_response(401)
    end

    test "a face survives a photo delete and loses to a photo upload", %{conn: conn, dir: dir} do
      user = AccountsFixtures.user_fixture()
      face_b = face_url("b")
      conn |> auth(user) |> put(~p"/api/v1/profile/avatar/face", %{"face" => "b"})

      assert %{"data" => %{"avatar_url" => photo}} =
               build_conn()
               |> auth(user)
               |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(png!(dir, "face.png"))})
               |> json_response(200)

      me = build_conn() |> auth(user) |> get(~p"/api/v1/auth/me") |> json_response(200)

      assert %{"avatar_face" => "b", "has_photo" => true, "avatar_url" => ^photo} =
               me["data"]["user"]

      assert build_conn()
             |> auth(user)
             |> delete(~p"/api/v1/profile/avatar")
             |> json_response(200) ==
               %{"data" => %{"avatar_url" => face_b}}

      me = build_conn() |> auth(user) |> get(~p"/api/v1/auth/me") |> json_response(200)

      assert %{"avatar_face" => "b", "has_photo" => false, "avatar_url" => ^face_b} =
               me["data"]["user"]
    end

    test "the face images are served as PNG" do
      for face <- ["a", "b"] do
        conn = get(build_conn(), "/images/faces/#{face}.png")
        assert response(conn, 200)
        assert ["image/png" <> _] = get_resp_header(conn, "content-type")
      end
    end
  end

  defp face_url(face), do: PidroServerWeb.Endpoint.url() <> "/images/faces/#{face}.png"

  defp assert_schema(response, name),
    do: OpenApiSpex.TestAssertions.assert_schema(response, name, PidroServerWeb.ApiSpec.spec())

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")

  defp upload(path),
    do: %Plug.Upload{path: path, filename: Path.basename(path), content_type: "image/png"}

  defp avatar_error(code, message),
    do: %{
      "errors" => %{"avatar" => [message]},
      "error_code" => code,
      "error_params" => %{},
      "field_errors" => [%{"field" => "avatar", "error_code" => code, "error_params" => %{}}]
    }

  defp png!(dir, name, color \\ "red") do
    path = Path.join(dir, name)
    {_, 0} = System.cmd("convert", ["-size", "320x200", "xc:#{color}", "PNG:#{path}"])
    path
  end
end

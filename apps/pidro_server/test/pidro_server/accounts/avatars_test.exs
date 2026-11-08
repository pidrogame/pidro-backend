defmodule PidroServer.Accounts.AvatarsTest do
  use PidroServer.DataCase, async: true

  import PidroServer.AccountsFixtures
  alias PidroServer.Accounts.{Auth, Avatars, UserAvatar}

  @version String.duplicate("f", 64)

  describe "resolve/3 (PID-395)" do
    test "a photo wins over a picked face" do
      id = Ecto.UUID.generate()

      assert Avatars.resolve(@version, "b", id) ==
               PidroServerWeb.Endpoint.url() <> "/api/v1/users/#{id}/avatar/#{@version}"
    end

    test "with no photo, the face the player picked" do
      assert Avatars.resolve(nil, "b", Ecto.UUID.generate()) ==
               PidroServerWeb.Endpoint.url() <> "/images/faces/b.png"
    end

    test "with no photo and no face, nil so the apps keep their own fallback" do
      assert Avatars.resolve(nil, nil, Ecto.UUID.generate()) == nil
    end
  end

  test "the batch lookup and the single-user answer agree for photo, face and never-picked" do
    photo = user_fixture()
    face = user_fixture()
    plain = user_fixture()

    Repo.insert!(
      UserAvatar.changeset(%UserAvatar{}, %{user_id: photo.id, image: "x", version: @version})
    )

    {:ok, photo} = Avatars.put_face(photo, "b")
    {:ok, face} = Avatars.put_face(face, "b")

    batch = Auth.get_users_map([photo.id, face.id, plain.id])

    assert batch[photo.id].avatar_url ==
             PidroServerWeb.Endpoint.url() <> "/api/v1/users/#{photo.id}/avatar/#{@version}"

    assert batch[face.id].avatar_url == PidroServerWeb.Endpoint.url() <> "/images/faces/b.png"
    assert batch[plain.id].avatar_url == nil

    for user <- [photo, face, plain] do
      assert batch[user.id].avatar_url == Avatars.url_for(user)
      assert {:ok, %{avatar_url: url}} = Auth.public_profile(user.id)
      assert url == batch[user.id].avatar_url
    end
  end

  test "put_face accepts only a and b" do
    user = user_fixture()
    assert {:error, %Ecto.Changeset{}} = Avatars.put_face(user, "c")
    assert {:error, %Ecto.Changeset{}} = Avatars.put_face(user, nil)
    assert {:ok, %{avatar_face: "a"}} = Avatars.put_face(user, "a")
  end
end

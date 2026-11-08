defmodule PidroServer.Accounts.Avatars do
  @moduledoc "Database-backed, normalized profile avatars."
  import Ecto.Query
  alias PidroServer.Accounts.{User, UserAvatar}
  alias PidroServer.Games.RoomManager
  alias PidroServer.Repo

  @max_upload 5 * 1024 * 1024
  @max_pixels 16_000_000
  @max_side 8192
  @limits ~w(-limit memory 64MiB -limit map 128MiB -limit disk 256MiB -limit thread 1 -limit time 10)

  def url(nil, _user_id), do: nil

  def url(version, user_id) do
    PidroServerWeb.Endpoint.url() <> "/api/v1/users/#{user_id}/avatar/#{version}"
  end

  @doc """
  The one avatar rule (PID-395): a photo wins; with no photo, the face the
  player picked; if they picked nothing, nil, so the apps draw their own.
  """
  def resolve(nil, nil, _user_id), do: nil

  def resolve(nil, face, _user_id),
    do: PidroServerWeb.Endpoint.url() <> "/images/faces/#{face}.png"

  def resolve(version, _face, user_id), do: url(version, user_id)

  @doc "`resolve/3` for one user, looking up their photo."
  def url_for(%User{} = user), do: resolve(metadata_for(user.id), user.avatar_face, user.id)

  @doc "What the player's own payloads say about their picture: /auth/me and GET /profile."
  def current_user_fields(user) do
    version = metadata_for(user.id)

    %{
      avatar_url: resolve(version, user.avatar_face, user.id),
      avatar_face: user.avatar_face,
      has_photo: version != nil
    }
  end

  def put_face(%User{} = user, face) do
    with {:ok, user} <- user |> User.face_changeset(%{avatar_face: face}) |> Repo.update() do
      RoomManager.identity_changed(user.id)
      {:ok, user}
    end
  end

  def metadata_for(user_id) do
    Repo.one(from a in UserAvatar, where: a.user_id == ^user_id, select: a.version)
  end

  def fetch(user_id, version) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id) do
      Repo.one(
        from a in UserAvatar,
          where: a.user_id == ^user_id and a.version == ^version,
          select: a.image
      )
    else
      :error -> nil
    end
  end

  def delete(user_id) do
    Repo.delete_all(from a in UserAvatar, where: a.user_id == ^user_id)
    RoomManager.identity_changed(user_id)
    nil
  end

  def put(user_id, %Plug.Upload{path: path}) do
    with {:ok, jpeg} <- normalize_upload(%Plug.Upload{path: path}) do
      version = :crypto.hash(:sha256, jpeg) |> Base.encode16(case: :lower)
      now = DateTime.utc_now()

      %UserAvatar{}
      |> UserAvatar.changeset(%{user_id: user_id, image: jpeg, version: version})
      |> Repo.insert(
        on_conflict: [set: [image: jpeg, version: version, updated_at: now]],
        conflict_target: :user_id
      )
      |> case do
        {:ok, _} ->
          RoomManager.identity_changed(user_id)
          {:ok, url(version, user_id)}

        error ->
          error
      end
    end
  end

  def put(_user_id, _), do: {:error, :missing_file}

  @doc "Validates and normalizes a bounded PNG/JPEG: square avatar or aspect-preserving News image."
  def normalize_upload(%Plug.Upload{path: path}, purpose \\ :avatar) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_upload || {:error, :too_large},
         {:ok, kind} <- supported_image(path),
         {:ok, jpeg} <-
           :global.trans(
             {__MODULE__, self()},
             fn -> process(path, kind, purpose) end,
             [node()],
             0
           ),
         true <- byte_size(jpeg) <= max_result(purpose) || {:error, :result_too_large} do
      {:ok, jpeg}
    else
      :aborted -> {:error, :busy}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_image}
      _ -> {:error, :invalid_image}
    end
  end

  defp max_result(:avatar), do: 64 * 1024
  defp max_result(:news), do: 512 * 1024

  defp process(path, kind, purpose) do
    with {:ok, {width, height}} <- dimensions(path, kind),
         true <-
           (width > 0 and height > 0 and width <= @max_side and height <= @max_side and
              width * height <= @max_pixels) || {:error, :dimensions} do
      normalize(path, kind, purpose)
    end
  end

  defp supported_image(path) do
    case File.read(path) do
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, :jpeg}
      {:ok, <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>} -> {:ok, :png}
      {:ok, _} -> {:error, :unsupported_type}
      error -> error
    end
  end

  defp dimensions(path, kind) do
    case System.cmd("identify", @limits ++ ["-ping", "-format", "%w %h", coder_path(path, kind)],
           stderr_to_stdout: true
         ) do
      {text, 0} ->
        case String.split(text) do
          [w, h] -> {:ok, {String.to_integer(w), String.to_integer(h)}}
          _ -> {:error, :invalid_image}
        end

      _ ->
        {:error, :invalid_image}
    end
  rescue
    _ -> {:error, :invalid_image}
  end

  defp normalize(path, kind, purpose) do
    output =
      Path.join(
        System.tmp_dir!(),
        "avatar-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.jpg"
      )

    args =
      @limits ++
        [
          coder_path(path, kind),
          "-auto-orient",
          "-colorspace",
          "sRGB"
        ] ++
        resize(purpose) ++
        [
          "-colorspace",
          "sRGB",
          "-background",
          "white",
          "-alpha",
          "remove",
          "-alpha",
          "off",
          "-strip",
          "-quality",
          "82",
          "JPEG:#{output}"
        ]

    try do
      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_, 0} -> File.read(output)
        _result -> {:error, :invalid_image}
      end
    rescue
      _error -> {:error, :invalid_image}
    after
      File.rm(output)
    end
  end

  defp resize(:avatar),
    do: ~w(-thumbnail 256x256^ -gravity center -background white -extent 256x256)

  defp resize(:news), do: ["-thumbnail", "1280x1280>"]

  defp coder_path(path, :jpeg), do: "JPEG:#{path}"
  defp coder_path(path, :png), do: "PNG:#{path}"
end

defmodule PidroServerWeb.API.AvatarController do
  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Accounts.Avatars
  alias PidroServerWeb.API.UserJSON
  alias PidroServerWeb.ErrorContract
  alias PidroServerWeb.Schemas.{ErrorSchemas, ProfileSchemas, UserSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Profiles"])

  operation(:create, false)
  operation(:delete, false)
  operation(:show, false)

  operation(:face,
    summary: "Pick the face shown while the player has no photo",
    description: """
    Sets the current user's `avatar_face` to `"a"` or `"b"` (PID-395). Guests
    may call it too. A photo still wins: `avatar_url` is the photo, else the
    face at `/images/faces/<face>.png`, else null. Picking a face keeps the
    photo, and removing the photo keeps the face.
    """,
    security: [%{"bearer_auth" => []}],
    request_body: {"Face", "application/json", ProfileSchemas.AvatarFaceRequest, required: true},
    responses: [
      ok: {"The current user", "application/json", UserSchemas.UserResponse},
      unauthorized:
        {"Authentication required or invalid", "application/json",
         ErrorSchemas.unauthorized_error()},
      unprocessable_entity:
        {"Face is not a or b", "application/json", ErrorSchemas.validation_error()}
    ]
  )

  def create(conn, %{"avatar" => upload}) do
    case Avatars.put(conn.assigns.current_user.id, upload) do
      {:ok, url} -> json(conn, %{data: %{avatar_url: url}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _), do: error(conn, :missing_file)

  def delete(conn, _params) do
    Avatars.delete(conn.assigns.current_user.id)
    json(conn, %{data: %{avatar_url: Avatars.url_for(conn.assigns.current_user)}})
  end

  def face(conn, params) do
    with {:ok, user} <- Avatars.put_face(conn.assigns.current_user, params["face"]) do
      conn |> put_view(UserJSON) |> render(:show, %{user: user})
    end
  end

  def show(conn, %{"user_id" => user_id, "version" => version}) do
    case Avatars.fetch(user_id, version) do
      nil ->
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "")

      bytes ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("etag", ~s("#{version}"))
        |> send_resp(200, bytes)
    end
  end

  defp error(conn, reason) do
    message =
      case reason do
        :too_large -> "avatar must be at most 5 MiB"
        :dimensions -> "avatar dimensions exceed the 16 megapixel or 8192 pixel limit"
        :unsupported_type -> "unsupported avatar type; upload JPEG or PNG"
        :missing_file -> "multipart field avatar is required"
        :result_too_large -> "processed avatar exceeds 64 KiB"
        :busy -> "photo processing is busy; please try again"
        _ -> "invalid avatar image"
      end

    code =
      case reason do
        :too_large -> :avatar_too_large
        :dimensions -> :avatar_dimensions
        :unsupported_type -> :avatar_unsupported_type
        :missing_file -> :field_required
        :result_too_large -> :avatar_result_too_large
        :busy -> :avatar_busy
        _ -> :avatar_invalid
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(if(reason == :busy, do: 503, else: 422))
    |> json(
      ErrorContract.add(
        %{errors: %{avatar: [message]}, field_errors: [ErrorContract.field(:avatar, code)]},
        code
      )
    )
  end
end

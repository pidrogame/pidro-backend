defmodule PidroServerWeb.API.BotCatalogueController do
  use PidroServerWeb, :controller
  alias PidroServer.BotCatalogue

  def index(conn, _params) do
    # Include disabled profiles so already seated identities remain resolvable;
    # `enabled` says who a seat plan may still choose (PID-410).
    profiles = Enum.uniq_by(BotCatalogue.profiles() ++ BotCatalogue.defaults(), & &1.id)
    enabled = Enum.map(BotCatalogue.available(), & &1.id)

    json(conn, %{
      data: Enum.map(profiles, &Map.put(BotCatalogue.public(&1), :enabled, &1.id in enabled))
    })
  end

  def avatar(conn, %{"id" => id, "version" => version}) do
    case BotCatalogue.fetch_image(id, version) do
      nil ->
        send_resp(conn, 404, "")

      image ->
        conn
        |> put_resp_content_type("image/jpeg", nil)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, image)
    end
  end
end

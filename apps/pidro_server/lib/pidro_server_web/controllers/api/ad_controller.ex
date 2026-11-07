defmodule PidroServerWeb.API.AdController do
  @moduledoc """
  What the app reports about the ad before a solo game (PID-123). Watched and
  unavailable both give the one credit the next solo room consumes; they
  differ only in what is counted.
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Ads
  alias PidroServerWeb.Schemas.ErrorSchemas

  tags(["Ads"])
  security([%{"bearer_auth" => []}])

  @unauthorized {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}

  operation(:watched,
    summary: "The ad was watched: one credit for the next solo room, valid 10 minutes",
    responses: [no_content: "Credit given", unauthorized: @unauthorized]
  )

  def watched(conn, _params), do: report(conn, :watched)

  operation(:unavailable,
    summary:
      "No ad could be shown (no fill, an error, no SDK): one credit for the next solo room, valid 10 minutes",
    responses: [no_content: "Credit given", unauthorized: @unauthorized]
  )

  def unavailable(conn, _params), do: report(conn, :unavailable)

  operation(:dismissed,
    summary: "The player backed out of the ad offer; counted, no credit",
    responses: [no_content: "Counted", unauthorized: @unauthorized]
  )

  def dismissed(conn, _params), do: report(conn, :dismissed)

  defp report(conn, kind) do
    :ok = Ads.report(conn.assigns.current_user, kind)
    send_resp(conn, :no_content, "")
  end
end

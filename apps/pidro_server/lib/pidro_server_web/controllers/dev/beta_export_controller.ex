defmodule PidroServerWeb.Dev.BetaExportController do
  @moduledoc false

  use PidroServerWeb, :controller

  alias PidroServer.Stats.BetaReport

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{BetaReport.classic_csv_filename()}")
    )
    |> send_resp(200, BetaReport.classic_csv())
  end
end

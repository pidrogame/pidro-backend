defmodule PidroServerWeb.MetaDataDeletionController do
  @moduledoc """
  `POST /meta/data-deletion`, Meta's data-deletion callback (PID-162), and
  `GET /meta/data-deletion/:code`, the status page its answer links to.

  No session and no CSRF check: Meta's `signed_request` is the only credential.
  Every request is also forwarded to Classic, which checks it itself.
  """

  use PidroServerWeb, :controller

  require Logger

  alias PidroServer.Accounts.FacebookDataDeletion
  alias PidroServer.Emails

  @csp "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"

  def create(conn, %{"signed_request" => signed_request}) when is_binary(signed_request) do
    FacebookDataDeletion.forward_to_classic(signed_request)

    case FacebookDataDeletion.request(signed_request) do
      {:ok, %{code: code}} ->
        json(conn, %{url: url(~p"/meta/data-deletion/#{code}"), confirmation_code: code})

      {:error, :invalid_credentials} ->
        bad_request(conn)

      {:error, reason} ->
        Logger.error("Facebook data-deletion request failed: #{inspect(reason)}")
        send_resp(conn, :internal_server_error, "")
    end
  end

  def create(conn, _params), do: bad_request(conn)

  def show(conn, %{"code" => code}) do
    case FacebookDataDeletion.get(code) do
      nil -> conn |> put_status(:not_found) |> page(nil)
      deletion -> page(conn, deletion)
    end
  end

  defp bad_request(conn),
    do: conn |> put_status(:bad_request) |> json(%{error: "invalid signed_request"})

  defp page(conn, deletion) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-robots-tag", "noindex")
    |> put_view(PidroServerWeb.MetaDataDeletionHTML)
    |> render(:show, deletion: deletion, support_email: Emails.delivery_setup().reply_to)
  end
end

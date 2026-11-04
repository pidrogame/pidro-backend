defmodule PidroServerWeb.API.FeedbackController do
  @moduledoc """
  Player feedback from the app (PID-316): notes, pace and old-Pidro answers.
  Only a registered player sends any (PID-348); a guest answers 403.
  """

  use PidroServerWeb, :controller

  alias PidroServer.Feedback
  alias PidroServerWeb.ErrorContract
  alias PidroServerWeb.Plugs.RateLimit

  action_fallback PidroServerWeb.API.FallbackController

  plug :require_account when action == :create
  plug :rate_limit when action == :create

  def create(conn, _params) do
    with {:ok, entry} <- Feedback.create(conn.body_params, conn.assigns.current_user) do
      conn |> put_status(:created) |> json(%{data: %{id: entry.id}})
    end
  end

  def ask(conn, _params), do: json(conn, %{data: Feedback.ask(conn.assigns.current_user)})

  defp require_account(%{assigns: %{current_user: %{guest: true}}} = conn, _opts) do
    error = %{
      code: "ACCOUNT_REQUIRED",
      title: "Account required",
      detail: "Sign in with an account to send feedback"
    }

    conn
    |> put_status(:forbidden)
    |> json(ErrorContract.add(%{errors: [error]}, :account_required))
    |> halt()
  end

  defp require_account(conn, _opts), do: conn

  # Notes and answers count in separate buckets, so an answer is never refused
  # because someone wrote a lot.
  defp rate_limit(conn, _opts) do
    policies =
      case conn.body_params do
        %{"kind" => "note"} -> [:feedback_note, :feedback_note_user]
        _answer -> [:feedback_answer]
      end

    conn |> put_private(:rate_limit, policies) |> RateLimit.call([])
  end
end

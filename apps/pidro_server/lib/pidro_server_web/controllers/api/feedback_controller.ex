defmodule PidroServerWeb.API.FeedbackController do
  @moduledoc "Player feedback from the app (PID-316): notes, pace and old-Pidro answers."

  use PidroServerWeb, :controller

  alias PidroServer.Feedback
  alias PidroServerWeb.Plugs.RateLimit

  action_fallback PidroServerWeb.API.FallbackController

  plug :rate_limit when action == :create

  def create(conn, _params) do
    with {:ok, entry} <- Feedback.create(conn.body_params, conn.assigns[:current_user]) do
      conn |> put_status(:created) |> json(%{data: %{id: entry.id}})
    end
  end

  def ask(conn, _params), do: json(conn, %{data: Feedback.ask(conn.assigns.current_user)})

  # Notes and answers count in separate buckets, so an answer is never refused
  # because someone wrote a lot. The player limit needs a player.
  defp rate_limit(conn, _opts) do
    policies =
      case {conn.body_params, conn.assigns[:current_user]} do
        {%{"kind" => "note"}, nil} -> [:feedback_note]
        {%{"kind" => "note"}, _user} -> [:feedback_note, :feedback_note_user]
        _answer -> [:feedback_answer]
      end

    conn |> put_private(:rate_limit, policies) |> RateLimit.call([])
  end
end

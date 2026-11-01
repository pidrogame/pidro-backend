defmodule PidroServer.Feedback do
  @moduledoc """
  Player feedback (PID-316): notes written in the app, mailed to support and
  worked through in `/admin/feedback`, and the one-tap pace and old-Pidro
  answers, counted by rule set.

  The app sends no game and no rule set: each row takes the player's latest
  finished game from `game_stats`, which never holds bots.
  """

  import Ecto.Query
  import Swoosh.Email, except: [from: 2]

  alias PidroServer.Emails
  alias PidroServer.Feedback.Entry
  alias PidroServer.Mailer
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

  @inbox "marcel@pidro.online"

  @doc """
  Saves a note or an answer from `user` (`nil` for no account) and mails a
  note to support. A failed mail is logged; the note is saved either way.
  """
  @spec create(map(), map() | nil) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def create(params, user) do
    game = game(user, params["game_id"])

    entry = %Entry{
      user_id: user && user.id,
      game_id: game && game.id,
      rule_set: game && game.rule_set
    }

    with {:ok, entry} <-
           entry |> Entry.changeset(params, user && user.email) |> Repo.insert(log: false) do
      if entry.kind == "note",
        do: entry |> note_email(user, game) |> Mailer.deliver_logged("Feedback")

      {:ok, entry}
    end
  end

  @doc """
  What to ask `user` on Home: `%{ask: "pace" | "old_pidro", game_id: id}`, or
  `%{ask: nil}`.

  Pace is asked once a UTC day, after a game with another person in the last
  24 hours. A Classic player is asked about the old Pidro once, from their
  third such game. A skipped question counts as answered.
  """
  @spec ask(map(), DateTime.t()) :: %{ask: String.t(), game_id: Ecto.UUID.t()} | %{ask: nil}
  def ask(user, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -24, :hour)
    today = DateTime.new!(DateTime.to_date(now), ~T[00:00:00])

    case user.id |> with_people() |> where([g], g.completed_at >= ^since) |> first_game() do
      nil ->
        %{ask: nil}

      %GameStats{id: game_id} ->
        cond do
          not answered?(user.id, "pace", today) -> %{ask: "pace", game_id: game_id}
          old_pidro?(user) -> %{ask: "old_pidro", game_id: game_id}
          true -> %{ask: nil}
        end
    end
  end

  @doc "The latest 200 notes, newest first, `\"open\"`, `\"done\"` or `\"all\"`."
  @spec list(String.t()) :: [Entry.t()]
  def list(status) do
    from(f in Entry, where: f.kind == "note", order_by: [desc: f.id], limit: 200, preload: :user)
    |> where_status(status)
    |> Repo.all()
  end

  @doc "Marks the note with `id` `\"open\"` or `\"done\"`."
  @spec set_status(integer() | String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_status(id, status) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Entry{} = note <- Repo.get_by(Entry, id: id, kind: "note") do
      note |> Entry.status_changeset(status) |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Answer counts, skips left out: `%{pace: %{{rule_set, answer} => n},
  old_pidro: %{answer => n}}`.
  """
  @spec counts() :: %{pace: map(), old_pidro: map()}
  def counts do
    rows =
      from(f in Entry,
        where: f.kind in ["pace", "old_pidro"] and f.answer != "skipped",
        group_by: [f.kind, f.rule_set, f.answer],
        select: {f.kind, f.rule_set, f.answer, count()}
      )
      |> Repo.all()

    %{
      pace: for({"pace", rule_set, answer, n} <- rows, into: %{}, do: {{rule_set, answer}, n}),
      old_pidro:
        for({"old_pidro", _rule_set, answer, n} <- rows, reduce: %{}) do
          acc -> Map.update(acc, answer, n, &(&1 + n))
        end
    }
  end

  defp where_status(query, "all"), do: query
  defp where_status(query, status), do: where(query, [f], f.status == ^status)

  # The game the answer names when the player was in it, else their latest.
  defp game(nil, _game_id), do: nil

  defp game(user, game_id) do
    named =
      case Ecto.UUID.cast(game_id) do
        {:ok, id} -> user.id |> games() |> where([g], g.id == ^id) |> first_game()
        :error -> nil
      end

    named || user.id |> games() |> first_game()
  end

  # `@>` can use the GIN index on player_ids; `= ANY` cannot.
  defp games(user_id),
    do:
      from(g in GameStats,
        where: fragment("? @> ?", g.player_ids, type(^[user_id], {:array, :binary_id}))
      )

  defp with_people(user_id),
    do: user_id |> games() |> where([g], fragment("cardinality(?) > 1", g.player_ids))

  defp first_game(query),
    do: query |> order_by([g], desc: g.completed_at) |> limit(1) |> Repo.one()

  defp old_pidro?(%{classic_user_id: nil}), do: false

  defp old_pidro?(user) do
    not answered?(user.id, "old_pidro", nil) and
      Repo.aggregate(with_people(user.id), :count) >= 3
  end

  defp answered?(user_id, kind, since) do
    Entry
    |> where([f], f.user_id == ^user_id and f.kind == ^kind)
    |> then(fn query -> if since, do: where(query, [f], f.inserted_at >= ^since), else: query end)
    |> Repo.exists?()
  end

  defp note_email(entry, user, game) do
    details = entry.details

    body = """
    #{entry.body}

    ---
    Feedback ##{entry.id}
    Player: #{player(user)}
    Reply to: #{entry.reply_email || "No reply address"}
    App: #{details["app_version"] || "unknown"} (build #{details["native_build"] || "?"}, update #{details["update_id"] || "?"}, #{details["channel"] || "?"})
    Device: #{details["platform"] || "?"} #{details["os_version"]}, #{details["device_model"] || "?"}
    Last game: #{if game, do: "#{game.id} (#{game.rule_set})", else: "None"}

    #{PidroServerWeb.Endpoint.url()}/admin/feedback
    """

    new()
    |> to(@inbox)
    |> Swoosh.Email.from({"Pidro", Emails.delivery_setup().from_address})
    |> subject(
      "Pidro ##{entry.id}: #{entry.body |> String.replace(~r/[\s[:cntrl:]]+/u, " ") |> String.trim() |> String.slice(0, 60)}"
    )
    |> text_body(body)
    |> then(fn email ->
      if entry.reply_email, do: reply_to(email, entry.reply_email), else: email
    end)
  end

  defp player(nil), do: "Guest, no account"
  defp player(user), do: "#{user.display_name || user.username} (#{user.id})"
end

defmodule PidroServer.Feedback do
  @moduledoc """
  Player feedback (PID-316): notes written in the app, mailed to support and
  worked through in `/admin/feedback`, and the one-tap pace and old-Pidro
  answers, counted by rule set.

  The app sends no game and no rule set: each row takes the player's latest
  finished game from `game_stats`, which never holds bots.

  A report (PID-329) is a note about a player, sent from the table: the
  server quotes what it saw, and it counts in no answers and lists apart.

  A note written back to a news post (PID-346) names it in `news_post_id`;
  an unknown id or a draft's is dropped, never refused.
  """

  import Ecto.Query
  import Swoosh.Email, except: [from: 2]

  alias PidroServer.Emails
  alias PidroServer.Feedback.Entry
  alias PidroServer.Mailer
  alias PidroServer.News
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
    post = if params["kind"] == "note", do: News.get_published(params["news_post_id"])

    entry = %Entry{
      user_id: user && user.id,
      game_id: game && game.id,
      rule_set: game && game.rule_set,
      news_post_id: post && post.id
    }

    with {:ok, entry} <-
           entry |> Entry.changeset(params, user && user.email) |> Repo.insert(log: false) do
      if entry.kind == "note",
        do: entry |> note_email(user, game, post) |> Mailer.deliver_logged("Feedback")

      {:ok, entry}
    end
  end

  @doc """
  Saves `reporter`'s report about `reported` and mails it to support.
  `game` is `%{key: id, instance: game_instance_id, room_code: code,
  rule_set: rule_set}`, `lines` the reported player's talk the room kept,
  oldest first: `%{text: text}` or `%{item: item}`. One report per
  reporter, reported player and game. A failed mail is logged; the report
  is saved either way.
  """
  @spec report(map(), map(), String.t(), map(), [map()]) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def report(reporter, reported, reason, game, lines) do
    entry = %Entry{
      user_id: reporter.id,
      reported_user_id: reported.id,
      rule_set: game.rule_set && to_string(game.rule_set),
      body: if(lines != [], do: Enum.map_join(lines, "\n", &quote_line/1)),
      details: %{
        "game" => game.key,
        "game_instance_id" => game.instance,
        "room_code" => game.room_code
      }
    }

    with {:ok, entry} <- entry |> Entry.report_changeset(reason) |> Repo.insert(log: false) do
      # Sent from the table, so a slow mail server must not hold the channel.
      email = report_email(entry, reporter, reported)

      Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
        Mailer.deliver_logged(email, "Report")
      end)

      {:ok, entry}
    end
  end

  @doc """
  What to ask `user` on Home: `%{ask: "pace" | "old_pidro", game_id: id}`, or
  `%{ask: nil}`.

  Pace is asked once a UTC day, after a game with another person in the last
  24 hours. A Classic player is asked about the old Pidro once, from their
  third such game. A skipped question counts as answered. A guest is never
  asked, because only a registered player sends feedback.
  """
  @spec ask(map(), DateTime.t()) :: %{ask: String.t(), game_id: Ecto.UUID.t()} | %{ask: nil}
  def ask(user, now \\ DateTime.utc_now())
  def ask(%{guest: true}, _now), do: %{ask: nil}

  def ask(user, now) do
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

  @doc """
  The latest 200 notes, newest first, `"open"`, `"done"` or `"all"`; with
  `"reports"` the latest 200 reports.
  """
  @spec list(String.t()) :: [Entry.t()]
  def list("reports") do
    from(f in Entry,
      where: f.kind == "report",
      order_by: [desc: f.id],
      limit: 200,
      preload: [:user, :reported_user]
    )
    |> Repo.all()
  end

  def list(status) do
    from(f in Entry,
      where: f.kind == "note",
      order_by: [desc: f.id],
      limit: 200,
      preload: [:user, :news_post]
    )
    |> where_status(status)
    |> Repo.all()
  end

  @doc "Marks the note or report with `id` `\"open\"` or `\"done\"`."
  @spec set_status(integer() | String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_status(id, status) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Entry{} = note <-
           Repo.one(from f in Entry, where: f.id == ^id and f.kind in ~w(note report)) do
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

  defp note_email(entry, user, game, post) do
    details = entry.details

    body = """
    #{entry.body}

    ---
    Feedback ##{entry.id}
    Player: #{player(user)}
    Reply to: #{entry.reply_email || "No reply address"}
    App: #{details["app_version"] || "unknown"} (build #{details["app_build"] || details["native_build"] || "?"}, update #{details["update_id"] || "?"}, #{details["channel"] || "?"})
    Device: #{details["platform"] || "?"} #{details["os_version"]}, #{details["device_model"] || "?"}
    Last game: #{if game, do: "#{game.id} (#{game.rule_set})", else: "None"}

    #{PidroServerWeb.Endpoint.url()}/admin/feedback
    """

    new()
    |> to(@inbox)
    |> Swoosh.Email.from({"Pidro", Emails.delivery_setup().from_address})
    |> subject(
      "#{if post, do: "Re: #{post.title_en} · "}Pidro ##{entry.id}: #{entry.body |> String.replace(~r/[\s[:cntrl:]]+/u, " ") |> String.trim() |> String.slice(0, 60)}"
    )
    |> text_body(body)
    |> then(fn email ->
      if entry.reply_email, do: reply_to(email, entry.reply_email), else: email
    end)
  end

  defp report_email(entry, reporter, reported) do
    body = """
    Reason: #{entry.answer}
    Game: #{entry.details["game_instance_id"] || "not started"} (room #{entry.details["room_code"]}, #{entry.rule_set || "?"})
    Reporter: #{player(reporter)}
    Reported: #{player(reported)}

    What #{name(reported)} said:
    #{entry.body || "Nothing at this table."}

    ---
    Report ##{entry.id}
    #{PidroServerWeb.Endpoint.url()}/admin/feedback?status=reports
    """

    new()
    |> to(@inbox)
    |> Swoosh.Email.from({"Pidro", Emails.delivery_setup().from_address})
    |> subject("Report: #{name(reporter)} about #{name(reported)}")
    |> text_body(body)
  end

  defp quote_line(%{text: text}), do: text
  defp quote_line(%{item: item}), do: "(#{item})"

  defp name(user), do: user.display_name || user.username

  defp player(nil), do: "Guest, no account"
  defp player(user), do: "#{user.display_name || user.username} (#{user.id})"
end

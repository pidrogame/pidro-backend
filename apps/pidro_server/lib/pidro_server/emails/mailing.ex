defmodule PidroServer.Emails.Mailing do
  @moduledoc """
  Sends a campaign template to every player in `Emails.campaign_recipients/0`,
  one mail at a time, and keeps its log in `EmailSend` and `EmailSendRecipient`.

  Delivery runs in one process under `PidroServer.TaskSupervisor`, registered
  under this module's name, so only one mailing runs at a time. Each
  recipient's row is claimed before the mailer gets the mail and settled
  after; a row left claimed by a crash or a deploy is never sent again. Five
  failures in a row pause the mailing. Nothing resumes by itself: `resume/1`
  sends only what is still pending.
  """

  import Ecto.Query

  alias PidroServer.Emails
  alias PidroServer.Emails.{EmailSend, EmailSendRecipient, EmailTemplate}
  alias PidroServer.Mailer
  alias PidroServer.Repo

  @topic "email_sends"
  @failures_to_pause 5
  @snapshot_fields [
    :name,
    :subject,
    :preview_text,
    :from_name,
    :from_email,
    :reply_to,
    :html_body,
    :variables
  ]

  @doc "Subscribes the caller to `:email_sends_changed`, sent whenever a mailing moves."
  def subscribe, do: Phoenix.PubSub.subscribe(PidroServer.PubSub, @topic)

  def running?, do: Process.whereis(__MODULE__) != nil

  @doc "What a mailing of `template` keeps of it: everything that shapes the mail."
  def snapshot(%EmailTemplate{} = template) do
    Map.new(@snapshot_fields, &{Atom.to_string(&1), Map.fetch!(template, &1)})
  end

  @doc "Starts a mailing of the saved `template` to every recipient it has now."
  def start(%EmailTemplate{id: template_id}, started_by) do
    run(fn ->
      template = Repo.get(EmailTemplate, template_id)
      blocker = template && Emails.campaign_send_blocker(template)

      cond do
        is_nil(template) -> {:error, :template_not_found}
        blocker -> {:error, {:blocked, blocker}}
        true -> create(template, started_by)
      end
    end)
  end

  @doc "Runs a paused or stopped mailing again, for its pending recipients only."
  def resume(send_id) do
    run(fn ->
      case Repo.update_all(from(s in EmailSend, where: s.id == ^send_id),
             set: [state: :running, paused_reason: nil, updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> {:ok, Repo.get!(EmailSend, send_id)}
        {0, _} -> {:error, :not_found}
      end
    end)
  end

  @doc "A template's mailings, newest first, each with `counts` of its rows by state."
  def list_sends(template_id) do
    sends =
      Repo.all(
        from s in EmailSend, where: s.template_id == ^template_id, order_by: [desc: s.inserted_at]
      )

    counts =
      Repo.all(
        from r in EmailSendRecipient,
          where: r.send_id in ^Enum.map(sends, & &1.id),
          group_by: [r.send_id, r.state],
          select: {r.send_id, r.state, count(r.id)}
      )

    zero = %{pending: 0, claimed: 0, sent: 0, failed: 0, skipped: 0}

    for send <- sends do
      counts = for {id, state, n} <- counts, id == send.id, into: zero, do: {state, n}
      %{send | counts: counts}
    end
  end

  # Starts the process and waits for `prepare` to answer under the lock: the
  # name is taken atomically, so a second mailing gets `:already_running`.
  defp run(prepare) do
    caller = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
        reply =
          if register() do
            mark_interrupted()
            prepare.()
          else
            {:error, :already_running}
          end

        send(caller, {ref, reply})
        with {:ok, %EmailSend{id: id}} <- reply, do: deliver(Repo.get!(EmailSend, id))
      end)

    monitor = Process.monitor(pid)

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        broadcast()
        reply

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :unavailable}
    end
  end

  defp register do
    Process.register(self(), __MODULE__)
  rescue
    ArgumentError -> false
  end

  # Holding the name, any send still marked running lost its process.
  defp mark_interrupted do
    Repo.update_all(from(s in EmailSend, where: s.state == :running),
      set: [state: :paused, paused_reason: "stopped by a restart", updated_at: DateTime.utc_now()]
    )
  end

  defp create(template, started_by) do
    Repo.transaction(fn ->
      send =
        %EmailSend{
          template_id: template.id,
          template: snapshot(template),
          started_by: started_by,
          state: :running
        }
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint(:state, name: :email_sends_one_running)
        |> Repo.insert()
        |> case do
          {:ok, send} -> send
          {:error, _changeset} -> Repo.rollback(:already_running)
        end

      now = DateTime.utc_now()

      Emails.campaign_recipients()
      |> Enum.map(
        &%{send_id: send.id, user_id: &1.id, state: :pending, inserted_at: now, updated_at: now}
      )
      |> Enum.chunk_every(1_000)
      |> Enum.each(&Repo.insert_all(EmailSendRecipient, &1))

      send
    end)
  end

  defp deliver(%EmailSend{template: snapshot} = send) do
    template =
      struct(
        EmailTemplate,
        [kind: :campaign] ++ for(f <- @snapshot_fields, do: {f, snapshot[Atom.to_string(f)]})
      )

    deliver(send.id, template, 0)
  end

  defp deliver(send_id, template, failures) do
    case next_pending(send_id) do
      nil ->
        update_send(send_id, state: :finished, finished_at: DateTime.utc_now())

      row ->
        result = deliver_row(template, row)
        broadcast()

        case {result, failures + 1} do
          {:stopped, _} ->
            :ok

          {:skipped, _} ->
            deliver(send_id, template, failures)

          {{:error, reason}, @failures_to_pause} ->
            update_send(send_id,
              state: :paused,
              paused_reason:
                "#{@failures_to_pause} failures in a row, the last #{inspect(failure_tag(reason))}"
            )

          {{:error, _reason}, in_a_row} ->
            pace()
            deliver(send_id, template, in_a_row)

          {:sent, _} ->
            pace()
            deliver(send_id, template, 0)
        end
    end
  end

  defp next_pending(send_id) do
    Repo.one(
      from r in EmailSendRecipient,
        where: r.send_id == ^send_id and r.state == :pending,
        order_by: r.id,
        limit: 1,
        preload: :user
    )
  end

  # A player who turned update emails off, or lost a sendable address, since
  # the send started is skipped. A send no longer running, paused from the
  # other container during a deploy, stops this loop.
  defp deliver_row(template, %EmailSendRecipient{user: user} = row) do
    with true <- is_nil(user.update_emails_off_at) and Mailer.sendable?(user.email || ""),
         1 <- claim(row) do
      result =
        with {:ok, email} <- Emails.campaign_email(template, user),
             do: Mailer.deliver_logged(email, "Mailing")

      case result do
        {:ok, _metadata} ->
          move(row, :claimed, :sent)
          :sent

        {:error, reason} ->
          move(row, :claimed, :failed)
          {:error, reason}
      end
    else
      false ->
        move(row, :pending, :skipped)
        :skipped

      0 ->
        :stopped
    end
  end

  defp claim(row) do
    running = from(s in EmailSend, where: s.id == ^row.send_id and s.state == :running)

    {count, _} =
      Repo.update_all(
        from(r in EmailSendRecipient,
          where: r.id == ^row.id and r.state == :pending and exists(subquery(running))
        ),
        set: [state: :claimed, updated_at: DateTime.utc_now()]
      )

    count
  end

  defp move(row, from, to) do
    {count, _} =
      Repo.update_all(
        from(r in EmailSendRecipient, where: r.id == ^row.id and r.state == ^from),
        set: [state: to, updated_at: DateTime.utc_now()]
      )

    count
  end

  defp update_send(send_id, changes) do
    Repo.update_all(from(s in EmailSend, where: s.id == ^send_id and s.state == :running),
      set: [updated_at: DateTime.utc_now()] ++ changes
    )

    broadcast()
  end

  # An SMTP failure such as `{:permanent_failure, host, message}` keeps its tag
  # only: the details can name the address.
  defp failure_tag(reason) do
    case Mailer.summary(reason) do
      :unknown when tuple_size(reason) > 0 and is_atom(elem(reason, 0)) -> elem(reason, 0)
      summary -> summary
    end
  end

  defp pace do
    :pidro_server
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval_ms, 1_000)
    |> Process.sleep()
  end

  defp broadcast, do: Phoenix.PubSub.broadcast(PidroServer.PubSub, @topic, :email_sends_changed)
end

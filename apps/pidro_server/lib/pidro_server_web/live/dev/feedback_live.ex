defmodule PidroServerWeb.Dev.FeedbackLive do
  @moduledoc """
  Player feedback (PID-316): the pace and old-Pidro answers, and the notes
  players wrote in the app, to work through and mark done. Reports about
  players (PID-329) sit behind their own filter. Data from
  `PidroServer.Feedback`.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Feedback

  @rule_sets [{"finnish", "Finnish"}, {"louisiana", "Louisiana"}]
  @pace [{"too_slow", "Too slow"}, {"right", "Right"}, {"too_fast", "Too fast"}]
  @old_pidro [{"worse", "Worse"}, {"same", "Same"}, {"better", "Better"}]
  @filters [{"open", "Open"}, {"done", "Done"}, {"all", "All"}, {"reports", "Reports"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Feedback",
       rule_sets: @rule_sets,
       pace: @pace,
       old_pidro: @old_pidro,
       filters: @filters
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in ~w(done all reports), do: params["status"], else: "open"
    {:noreply, socket |> assign(status: status) |> load()}
  end

  @impl true
  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    case Feedback.set_status(id, status) do
      {:ok, _note} ->
        {:noreply, load(socket)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "That note could not be changed.") |> load()}
    end
  end

  defp load(socket),
    do: assign(socket, counts: Feedback.counts(), notes: Feedback.list(socket.assigns.status))

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="feedback"
      title="Feedback"
      subtitle="What players tell us from inside the app, and how the pace feels. Skipped questions are not counted."
      flash={@flash}
    >
      <section
        id="feedback-answers"
        class="overflow-hidden rounded-lg border border-stone-200 bg-white"
      >
        <h2 class="border-b border-stone-200 px-4 py-3 text-sm font-semibold text-stone-950">
          Answers
        </h2>
        <table class="min-w-full divide-y divide-stone-200 text-sm">
          <thead class="bg-stone-50">
            <tr>
              <th class="px-4 py-2 text-left text-xs font-medium text-stone-500">Pace</th>
              <th
                :for={{_key, label} <- @pace}
                class="w-32 px-4 py-2 text-right text-xs font-medium text-stone-500"
              >
                {label}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-stone-100">
            <tr :for={{rule_set, name} <- @rule_sets} id={"pace-#{rule_set}"}>
              <td class="px-4 py-2.5 font-medium text-stone-900">{name}</td>
              <td
                :for={{answer, _label} <- @pace}
                class="px-4 py-2.5 text-right font-mono tabular-nums text-stone-900"
              >
                {Map.get(@counts.pace, {rule_set, answer}, 0)}
              </td>
            </tr>
          </tbody>
          <thead class="bg-stone-50">
            <tr>
              <th class="px-4 py-2 text-left text-xs font-medium text-stone-500">
                Compared with the old Pidro
              </th>
              <th
                :for={{_key, label} <- @old_pidro}
                class="px-4 py-2 text-right text-xs font-medium text-stone-500"
              >
                {label}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr id="old-pidro">
              <td class="px-4 py-2.5 font-medium text-stone-900">Classic players</td>
              <td
                :for={{answer, _label} <- @old_pidro}
                class="px-4 py-2.5 text-right font-mono tabular-nums text-stone-900"
              >
                {Map.get(@counts.old_pidro, answer, 0)}
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section id="feedback-notes" class="overflow-hidden rounded-lg border border-stone-200 bg-white">
        <div class="flex items-center justify-between border-b border-stone-200 px-4 py-3">
          <h2 class="text-sm font-semibold text-stone-950">
            {if @status == "reports", do: "Reports", else: "Notes"}
          </h2>
          <nav class="flex gap-1 text-sm" aria-label="Note status">
            <.link
              :for={{status, label} <- @filters}
              patch={~p"/admin/feedback?#{[status: status]}"}
              class={[
                "rounded-md px-2.5 py-1 font-medium",
                if(@status == status,
                  do: "bg-stone-950 text-white",
                  else: "text-stone-600 hover:text-stone-950"
                )
              ]}
            >
              {label}
            </.link>
          </nav>
        </div>
        <p :if={@notes == []} class="px-4 py-6 text-sm text-stone-500">
          {if @status == "reports", do: "No reports.", else: "No notes here."}
        </p>
        <article
          :for={report <- @notes}
          :if={@status == "reports"}
          id={"report-#{report.id}"}
          class="flex flex-col gap-3 border-b border-stone-100 px-4 py-4 last:border-b-0 lg:flex-row"
        >
          <div class="w-56 shrink-0 space-y-1 text-xs text-stone-500">
            <p class="font-mono text-sm font-semibold text-stone-950">#{report.id}</p>
            <p>{Calendar.strftime(report.inserted_at, "%Y-%m-%d %H:%M")} UTC</p>
            <p>From <.who user={report.user} /></p>
            <p>About <.who user={report.reported_user} /></p>
            <p>
              <span class="rounded bg-rose-50 px-1.5 py-0.5 font-medium text-rose-800">
                {report.answer}
              </span>
            </p>
            <p>
              <.link
                :if={report.details["game_instance_id"]}
                navigate={~p"/admin/history/#{report.details["game_instance_id"]}"}
                class="underline"
              >
                Game · room {report.details["room_code"]}
              </.link>
              <span :if={!report.details["game_instance_id"]}>
                Room {report.details["room_code"]}, before the game
              </span>
            </p>
          </div>
          <p
            phx-no-format
            class="min-w-0 flex-1 whitespace-pre-wrap break-words font-mono text-sm leading-6 text-stone-900"
          >{report.body || "Nothing said at this table."}</p>
          <div class="shrink-0">
            <.status_button entry={report} />
          </div>
        </article>
        <article
          :for={note <- @notes}
          :if={@status != "reports"}
          id={"note-#{note.id}"}
          class="flex flex-col gap-3 border-b border-stone-100 px-4 py-4 last:border-b-0 lg:flex-row"
        >
          <div class="w-56 shrink-0 space-y-1 text-xs text-stone-500">
            <p class="font-mono text-sm font-semibold text-stone-950">#{note.id}</p>
            <p>{Calendar.strftime(note.inserted_at, "%Y-%m-%d %H:%M")} UTC</p>
            <p>
              <.link
                :if={note.user}
                navigate={~p"/admin/users/#{note.user.id}"}
                class="font-medium text-stone-900 underline"
              >
                {note.user.display_name || note.user.username}
              </.link>
              <span :if={!note.user} class="font-medium text-stone-900">Guest</span>
            </p>
            <p>{note.reply_email || "No reply address"}</p>
            <p>App {note.details["app_version"] || "?"} · {device(note.details)}</p>
            <p :if={note.game_id}>
              <.link navigate={~p"/admin/history/summaries/#{note.game_id}"} class="underline">
                Last game · {note.rule_set}
              </.link>
            </p>
          </div>
          <p
            phx-no-format
            class="min-w-0 flex-1 whitespace-pre-wrap break-words text-sm leading-6 text-stone-900"
          >{note.body}</p>
          <div class="shrink-0">
            <.status_button entry={note} />
          </div>
        </article>
      </section>
    </.admin_shell>
    """
  end

  defp status_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_status"
      phx-value-id={@entry.id}
      phx-value-status={if @entry.status == "open", do: "done", else: "open"}
      class={[
        "rounded-md px-3 py-1.5 text-sm font-semibold",
        if(@entry.status == "open",
          do: "bg-stone-950 text-white hover:bg-stone-800",
          else: "border border-stone-300 bg-white text-stone-700 hover:text-stone-950"
        )
      ]}
    >
      {if @entry.status == "open", do: "Done", else: "Reopen"}
    </button>
    """
  end

  defp who(%{user: nil} = assigns),
    do: ~H|<span class="font-medium text-stone-900">a deleted player</span>|

  defp who(assigns) do
    ~H"""
    <.link navigate={~p"/admin/users/#{@user.id}"} class="font-medium text-stone-900 underline">
      {@user.display_name || @user.username}
    </.link>
    <span :if={@user.guest}>(guest)</span>
    """
  end

  defp device(details) do
    [details["platform"], details["os_version"], details["device_model"]]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "unknown device"
      parts -> Enum.join(parts, " ")
    end
  end
end

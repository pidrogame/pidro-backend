defmodule PidroServerWeb.Dev.HistoryLive do
  @moduledoc "Authenticated, read-only archive and client incident inspection."
  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents
  alias PidroServer.Admins
  alias PidroServerWeb.CardComponents
  alias PidroServerWeb.Dev.ArchivePresentation, as: Presentation
  alias PidroServerWeb.Dev.HistoryInspector

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       token: session["admin_token"],
       data: %{},
       error: nil,
       timer: nil,
       playing: false,
       speed: "1",
       playback_notice: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = pause(socket)
    # Private hands and client evidence require a real admin, even in dev.
    # Revalidate on URL patches as well as the shared hook's events.
    case Admins.get_admin_by_session_token(socket.assigns.token) do
      %{force_password_change: false} ->
        params = Map.take(params, ["id" | HistoryInspector.fields()])
        socket = assign(socket, params: params, page_title: title(socket.assigns.live_action))

        case HistoryInspector.load(socket.assigns.live_action, params) do
          {:ok, data} -> {:noreply, assign(socket, data: data, error: nil, playback_notice: nil)}
          {:error, error} -> {:noreply, assign(socket, data: %{}, error: error)}
        end

      %{force_password_change: true} ->
        {:noreply, redirect(socket, to: ~p"/admin/admins")}

      _ ->
        {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    with_admin(socket, fn socket -> playback_event(event, params, socket) end)
  end

  @impl true
  def handle_info({:playback, tag}, %{assigns: %{timer: {_ref, tag}, playing: true}} = socket) do
    with_admin(socket, fn socket ->
      socket |> assign(:timer, nil) |> select_checkpoint("next") |> schedule()
    end)
  end

  def handle_info({:playback, _stale}, socket), do: {:noreply, socket}

  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report_once(__MODULE__, message)
    {:noreply, socket}
  end

  defp with_admin(socket, fun) do
    case Admins.get_admin_by_session_token(socket.assigns.token) do
      %{force_password_change: false} ->
        {:noreply, fun.(socket)}

      %{force_password_change: true} ->
        {:noreply, socket |> pause() |> redirect(to: ~p"/admin/admins")}

      _ ->
        {:noreply, socket |> pause() |> redirect(to: ~p"/admin/login")}
    end
  end

  defp playback_event("toggle_playback", _, %{assigns: %{playing: true}} = socket),
    do: pause(socket)

  defp playback_event("toggle_playback", _, socket) do
    if playable?(socket.assigns.data) and socket.assigns.data.checkpoints.count > 1 do
      data = socket.assigns.data

      socket =
        if data.revision >= data.checkpoints.last,
          do: socket |> assign(:playing, true) |> select_checkpoint("first"),
          else: assign(socket, :playing, true)

      schedule(socket)
    else
      socket
    end
  end

  defp playback_event("step", %{"direction" => direction}, socket)
       when direction in ~w(first previous next last) do
    socket |> pause() |> select_checkpoint(direction)
  end

  defp playback_event("seek", %{"checkpoint" => value}, socket) when is_binary(value) do
    case Integer.parse(value) do
      {index, ""} when index >= 0 and index <= 9_007_199_254_740_991 ->
        socket |> cancel_timer() |> select_checkpoint("seek", index) |> schedule()

      _ ->
        socket
    end
  end

  defp playback_event("speed", %{"speed" => speed}, socket) when speed in ~w(0.5 1 2 4),
    do: socket |> cancel_timer() |> assign(:speed, speed) |> schedule()

  defp playback_event(_, _, socket), do: socket

  defp playable?(%{archive: archive, checkpoints: %{count: count}}),
    do: archive.format_version == 1 and count > 0

  defp playable?(_), do: false

  defp select_checkpoint(socket, direction, revision \\ nil) do
    if playable?(socket.assigns.data) do
      data = socket.assigns.data
      target = revision || data.revision

      case HistoryInspector.checkpoint(
             data.archive.game_instance_id,
             direction,
             target,
             data.checkpoints
           ) do
        {:ok, nil} ->
          socket
          |> pause()
          |> assign(
            :playback_notice,
            "No saved checkpoint in this direction. Evidence may have expired; reload to refresh."
          )

        {:ok, checkpoint} ->
          notice =
            cond do
              direction in ~w(next previous) and abs(checkpoint.revision - data.revision) > 1 ->
                "Missing revisions skipped between #{min(data.revision, checkpoint.revision)} and #{max(data.revision, checkpoint.revision)}; no state reconstructed."

              true ->
                nil
            end

          socket
          |> assign(data: Map.merge(data, checkpoint), playback_notice: notice)
          |> then(fn socket ->
            if checkpoint.revision == data.checkpoints.last, do: pause(socket), else: socket
          end)

        {:error, message} ->
          socket |> pause() |> assign(:playback_notice, message)
      end
    else
      pause(socket)
    end
  end

  defp schedule(%{assigns: %{playing: true, timer: nil}} = socket) do
    if connected?(socket) do
      tag = make_ref()
      delay = %{"0.5" => 2000, "1" => 1000, "2" => 500, "4" => 250}[socket.assigns.speed]
      ref = Process.send_after(self(), {:playback, tag}, delay)
      assign(socket, :timer, {ref, tag})
    else
      socket
    end
  end

  defp schedule(socket), do: socket

  defp cancel_timer(socket) do
    if socket.assigns.timer, do: Process.cancel_timer(elem(socket.assigns.timer, 0))
    assign(socket, :timer, nil)
  end

  defp pause(socket), do: socket |> cancel_timer() |> assign(:playing, false)

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="history"
      title={@page_title}
      class="admin-game-inspection"
      subtitle="Private admin evidence · Read-only · Display timezone: UTC"
      flash={@flash}
    >
      <:actions>
        <.link navigate={~p"/admin/history"} class="underline">Archives</.link>
        <.link navigate={~p"/admin/reports"} class="underline">Incident reports</.link>
        <.link navigate={~p"/admin/history/summaries"} class="underline">Completed summaries</.link>
      </:actions>
      <.search
        :if={@live_action in [:archives, :reports, :summaries]}
        action={@live_action}
        params={@params}
      />
      <p :if={@error} role="alert" class="rounded-lg border border-rose-300 bg-rose-50 p-4">
        {@error}
      </p>
      <%= if !@error do %>
        <.results
          :if={@live_action in [:archives, :reports, :summaries]}
          action={@live_action}
          data={@data}
          params={@params}
        />
        <.archive
          :if={@live_action == :archive}
          data={@data}
          params={@params}
          playing={@playing}
          speed={@speed}
          notice={@playback_notice}
        />
        <.report :if={@live_action == :report} data={@data} />
        <.summary :if={@live_action == :summary} data={@data} />
      <% end %>
    </.admin_shell>
    """
  end

  defp search(assigns) do
    ~H"""
    <form
      action={list_path(@action)}
      method="get"
      id="history-search"
      class="rounded-lg border border-stone-200 bg-white p-4"
    >
      <div class="grid gap-3 sm:grid-cols-3">
        <.filter
          name="player"
          label="Player (exact name)"
          params={@params}
          placeholder="Username or display name"
        />
        <.filter name="room_code" label="Room code" params={@params} placeholder="ABCD" />
        <label :if={@action == :archives} class="text-sm">
          Outcome
          <select name="status" class="mt-1 block min-h-11 w-full rounded-md border-stone-300">
            <option
              :for={
                {value, label} <- [
                  {"", "All outcomes"},
                  {"active", "Live / unclosed"},
                  {"complete", "Completed"},
                  {"closed", "Abandoned / closed"},
                  {"interrupted", "Interrupted"}
                ]
              }
              value={value}
              selected={@params["status"] == value}
            >
              {label}
            </option>
          </select>
        </label>
      </div>
      <div class="history-search-actions mt-3 flex flex-wrap items-center gap-4">
        <button class="min-h-11 rounded-md bg-stone-950 px-4 py-2 text-sm font-semibold text-white"><.icon
          name="hero-magnifying-glass"
          class="size-4"
        />Search</button>
        <.link
          navigate={list_path(@action)}
          class="inline-flex min-h-11 items-center text-sm underline"
        >Clear filters</.link>
      </div>
      <details
        class="mt-3"
        open={
          Enum.any?(
            ~w(user_id game_instance_id from to report_id build),
            &(@params[&1] not in [nil, ""])
          )
        }
      >
        <summary class="min-h-11 cursor-pointer py-3 text-sm font-medium">
          More filters · dates and exact IDs
        </summary>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.filter name="user_id" label="User ID" params={@params} placeholder="UUID" />
          <.filter
            name="game_instance_id"
            label="Game instance (exact)"
            params={@params}
            placeholder="Not the room code"
          />
          <.filter
            name="from"
            label={
              if @action == :summaries, do: "Completed from (inclusive)", else: "From (inclusive)"
            }
            params={@params}
            placeholder="2026-10-22T00:00:00Z"
          />
          <.filter
            name="to"
            label="To (exclusive)"
            params={@params}
            placeholder="2026-10-23T00:00:00Z"
          />
          <.filter
            :if={@action == :reports}
            name="report_id"
            label="Report ID"
            params={@params}
            placeholder="UUID"
          />
          <.filter
            :if={@action == :reports}
            name="build"
            label="Client build (claimed)"
            params={@params}
            placeholder="123"
          />
        </div>
        <p class="text-xs text-stone-500">
          ISO 8601 with offset; displayed in UTC. {if @action == :archives,
            do: "Time filters use game start."} 25 results per page.
        </p>
      </details>
    </form>
    """
  end

  defp filter(assigns) do
    ~H"""
    <label class="text-sm">
      {@label}
      <input
        name={@name}
        value={if is_binary(@params[@name]), do: @params[@name], else: ""}
        placeholder={@placeholder}
        maxlength="80"
        class="mt-1 block min-h-11 w-full rounded-md border-stone-300 text-sm"
      />
    </label>
    """
  end

  defp results(assigns) do
    ~H"""
    <p class="text-sm text-stone-600">{list_notice(@action)}</p>
    <.empty_state
      :if={@data.rows == []}
      title="No matching evidence"
      body="No records match these filters. Older, expired or never-saved games may have no archive; absence is not proof a game never happened."
    />
    <div>
      <div :if={@action == :archives && @data.rows != []} class="match-columns" aria-hidden="true">
        <span>Table / room</span><span>Initial roster · current profiles</span><span>Outcome / evidence</span><span>Recorded · UTC</span><span>Action</span>
      </div>
      <div class={if @action == :archives, do: "match-list", else: "space-y-3"} id="history-results">
        <article
          :for={row <- @data.rows}
          class={
            if @action == :archives,
              do: "match-row",
              else: "rounded-lg border border-stone-200 bg-white p-4"
          }
        >
          <%= if @action == :archives do %>
            <div class="match-room">
              <.link
                navigate={detail_path(@action, row)}
                class="match-title"
              ><.icon name="hero-rectangle-stack" class="size-4 shrink-0" />Room {row.room_code}</.link>
              <details class="match-identifiers">
                <summary>Instance and evidence</summary>
                <p class="break-all">{row.game_instance_id || "No recorded instance"}</p>
                <p :if={@action == :archives}>Last saved revision {row.last_revision}</p>
              </details>
            </div>
            <.participant_teams seats={Presentation.teams(row.participants, @data.names)} />
            <div class="match-state">
              <.match_status status={row.status} />
              <p class={[
                "mt-2 flex items-center gap-1 text-xs",
                if(row.evidence_status == "continuous", do: "text-stone-600", else: "text-amber-800")
              ]}>
                <.icon
                  name={
                    if row.evidence_status == "continuous",
                      do: "hero-document-check",
                      else: "hero-exclamation-triangle"
                  }
                  class="size-4 shrink-0"
                />
                {evidence(row.evidence_status)}
              </p>
              <p :if={row.participants == %{}} class="mt-1 text-xs text-stone-500">
                No initial seat evidence
              </p>
            </div>
            <div class="match-time">
              <p>{row_time(@action, row)}</p>
              <p>Last saved {utc(row.saved_at)}</p>
              <p :if={row.ended_at}>Ended {utc(row.ended_at)}</p>
            </div>
            <div class="match-actions">
              <.link navigate={detail_path(@action, row)} class="match-primary">
                <.icon name="hero-magnifying-glass" class="size-4" />Inspect
              </.link>
            </div>
          <% else %>
            <div class="flex flex-wrap items-center justify-between gap-2">
              <.link
                navigate={detail_path(@action, row)}
                class="inline-flex min-h-11 items-center font-semibold text-stone-950"
              >Room {row.room_code}</.link>
              <div class="flex items-center gap-3 text-sm">
                <span class="rounded bg-stone-100 px-2 py-1">{row_label(@action, row)}</span>
                <.link
                  navigate={detail_path(@action, row)}
                  class="inline-flex min-h-11 items-center font-medium text-indigo-700 underline"
                >Inspect</.link>
              </div>
            </div>
            <p class="mt-2 text-sm">{row_time(@action, row)}</p>
            <details class="mt-3 border-t border-stone-100 pt-2 text-xs text-stone-500">
              <summary class="min-h-11 cursor-pointer py-3">Instance and evidence</summary>
              <p class="break-all">{row.game_instance_id || "No recorded instance"}</p>
            </details>
          <% end %>
          <p :if={@action == :reports} class="mt-1 break-all text-sm">
            Report {row.id} · User {row.user_id} · Build {row.build}
          </p>
        </article>
      </div>
    </div>
    <.link
      :if={@data.next}
      navigate={query_path(list_path(@action), Map.merge(@params, @data.next))}
      class="inline-block rounded-md border bg-white px-4 py-2"
    >Older results →</.link>
    """
  end

  defp archive(assigns) do
    ~H"""
    <%= if @data.archive do %>
      <section class="playback-heading">
        <h2 class="flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-rectangle-stack" class="size-5" />Room {@data.archive.room_code}
        </h2>
        <.match_status status={@data.archive.status} />
        <p class="text-xs text-stone-600">Started {utc(@data.archive.started_at)}</p>
        <p class="playback-roster-note">
          Initial participants · current account names and avatars. Seat and connection facts are from game start, not this checkpoint.
        </p>
      </section>
      <.saved_table data={@data} params={@params} playing={@playing} speed={@speed} notice={@notice} />
      <details id="archive-evidence" class="playback-evidence">
        <summary class="min-h-11 cursor-pointer py-3 font-semibold">
          Archive evidence and initial seat IDs
        </summary>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="break-all text-lg font-semibold">
            Room {@data.archive.room_code} · {@data.archive.game_instance_id}
          </h2>
          <span class="rounded bg-amber-50 px-3 py-1 text-sm">{outcome(@data.archive.status)} · {evidence(
            @data.archive.evidence_status
          )}</span>
        </div>
        <p class="mt-2 text-sm">
          Started {utc(@data.archive.started_at)} · Last saved revision {@data.archive.last_revision} at {utc(
            @data.archive.saved_at
          )}
        </p>
        <p class="mt-2 text-sm">
          Terminal observation: {utc(@data.archive.ended_at)} · Reason: {@data.archive.termination_reason ||
            "None saved"}
        </p>
        <p :if={@data.archive.status == "interrupted"} class="mt-2 text-sm">
          Interrupted time is when the missing process was detected, not a known crash time.
        </p>
        <p :if={@data.archive.status == "active"} class="mt-2 text-sm">
          Live / unclosed means no terminal observation was saved. It does not guarantee the process is still running or this is its latest state.
        </p>
        <p class="mt-2 text-sm">
          Missing checkpoints: {@data.archive.missing_revision_count} · Failed writes: {@data.archive.failed_checkpoints}. Continuous evidence does not guarantee the current live tail.
        </p>
        <div class="mt-3 flex flex-wrap gap-4 text-sm underline">
          <.link navigate={~p"/admin/history?#{%{room_code: @data.archive.room_code}}"}>Other instances in this room (including rematches)</.link>
          <.link navigate={~p"/admin/reports?#{%{game_instance_id: @data.archive.game_instance_id}}"}>Reports for this exact instance</.link>
        </div>
        <h2 class="mt-4 font-semibold">Initial participants</h2>
        <p class="text-xs text-stone-500">
          Names and avatars are current account labels; seat facts are from game start, not a complete replacement or connection history.
        </p>
        <.participant_teams seats={Presentation.teams(@data.archive.participants, @data.names)} />
        <p :if={@data.archive.participants == %{}} class="mt-2 text-sm">
          No initial seat evidence was captured.
        </p>
        <p :if={@data.archive.participation_truncated} class="mt-2 text-sm text-amber-800">
          The participation index reached its limit. Player search may omit later participants.
        </p>
        <ul class="mt-2 grid gap-2 sm:grid-cols-2">
          <li
            :for={{position, seat} <- Enum.sort(@data.archive.participants)}
            class="break-all text-sm"
          >
            <strong>{position}</strong>
            · {Presentation.participant_name(seat, @data.names)} · {seat["occupant_type"]}
            <.link
              :if={valid_uuid?(seat["user_id"])}
              navigate={~p"/admin/users/#{seat["user_id"]}"}
              class="underline"
            >{seat["user_id"]}</.link>
          </li>
        </ul>
      </details>
      <details
        id="timeline-details"
        open={@params["after_revision"] not in [nil, ""]}
        class="playback-evidence"
      >
        <summary class="min-h-11 cursor-pointer py-3 font-semibold">
          Authoritative saved timeline
        </summary>
        <p class="mt-1 text-sm text-stone-500">
          Ordered by server revision; missing revisions are explicit. Connection events appear only if captured; client connections are claims in reports.
        </p>
        <ol class="mt-4 space-y-4" id="archive-timeline">
          <li :for={event <- @data.events} class="border-l-2 border-stone-300 pl-4">
            <.link
              patch={
                ~p"/admin/history/#{@data.archive.game_instance_id}?#{%{revision: event.revision, after_revision: @params["after_revision"] || ""}}"
              }
              class="font-semibold underline"
            >Revision {event.revision} · {event.payload["kind"]}</.link>
            <p class="text-xs text-stone-500">
              Observed {utc(event.occurred_at)} · Saved {utc(event.saved_at)}
            </p>
            <p :if={event.payload["missing_revisions"]} class="text-sm text-amber-800">
              Missing revision range (inclusive): {Enum.join(event.payload["missing_revisions"], "–")}
            </p>
            <p :if={event.payload["action"]} class="mt-1 break-words text-sm">
              {event_actor(event.payload["position"], @data)}: {Presentation.describe(
                event.payload["action"]
              )}
            </p>
            <p :if={event.payload["events_replaced"]} class="text-xs text-amber-800">
              Engine event list replaced at this checkpoint.
            </p>
            <ul class="mt-1 space-y-1 text-sm">
              <li :for={fact <- event.payload["engine_events"] || []} class="break-words">
                {Presentation.describe(fact)}
              </li>
            </ul>
          </li>
        </ol>
        <p :if={@data.events == []} class="mt-3 text-sm">
          No more saved events. No missing history is inferred.
        </p>
        <.link
          :if={@data.next_event}
          patch={
            ~p"/admin/history/#{@data.archive.game_instance_id}?#{%{after_revision: @data.next_event, revision: @data.revision}}"
          }
          class="mt-4 inline-block underline"
        >Next saved events →</.link>
      </details>
      <details class="playback-evidence">
        <summary class="min-h-11 cursor-pointer py-3 font-semibold">
          Linked client incident reports ({length(@data.reports)}{if length(@data.reports) == 25,
            do: "+"})
        </summary>
        <.link
          navigate={~p"/admin/reports?#{%{game_instance_id: @data.archive.game_instance_id}}"}
          class="text-sm underline"
        >Browse all reports for this instance</.link>
        <p :if={@data.reports == []} class="mt-2 text-sm">
          No retained reports for this exact instance.
        </p>
        <p :for={report <- @data.reports} class="mt-2 break-all text-sm">
          <.link navigate={~p"/admin/reports/#{report.id}"} class="underline">{report.id}</.link>
          · {utc(report.inserted_at)} · Build {report.build}
        </p>
      </details>
    <% else %>
      <.empty_state
        title="No archive for this instance"
        body="The game may predate archiving, have expired, or never have saved evidence. Check completed summaries; a room code alone cannot identify this game."
      />
    <% end %>
    """
  end

  defp saved_table(assigns) do
    assigns = assign(assigns, :playable, playable?(assigns.data))

    ~H"""
    <section id="saved-playback" class="playback-workspace">
      <p
        :if={
          @data.archive.evidence_status != "continuous" || @data.archive.missing_revision_count > 0 ||
            @data.archive.failed_checkpoints > 0
        }
        id="archive-gap-warning"
        class="playback-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <span>{evidence(@data.archive.evidence_status)} · Missing checkpoints: {@data.archive.missing_revision_count} · Failed writes: {@data.archive.failed_checkpoints}. Missing state is never reconstructed.</span>
      </p>
      <%= cond do %>
        <% is_nil(@data.snapshot) -> %>
          <p class="playback-warning">
            No saved snapshot at this revision. A gap is not reconstructed.
          </p>
        <% @data.archive.format_version != 1 -> %>
          <p class="playback-warning">
            Unsupported archive format. Table cannot be safely rendered; saved data remains below.
          </p>
        <% true -> %>
          <CardComponents.watch_table
            game_state={Presentation.state(@data.snapshot)}
            seats={Presentation.seats(@data.archive.participants, @data.names)}
            perspective={:all}
          />
      <% end %>
      <div class="playback-controls">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h2 id="checkpoint-label" class="font-semibold">
            Saved table · {if @data.snapshot,
              do: "revision #{@data.revision}",
              else: "snapshot unavailable"}
          </h2>
          <span id="playback-state" role="status" class="text-sm text-stone-500">{cond do
            @playing -> "Playing"
            @data.checkpoints.count == 0 -> "No saved checkpoints"
            @data.revision == @data.checkpoints.last -> "End of saved checkpoints"
            true -> "Paused"
          end}</span>
        </div>
        <div class="playback-transport">
          <div class="playback-buttons">
            <button
              :for={
                {direction, label, icon} <- [
                  {"first", "First", "hero-backward"},
                  {"previous", "Previous", "hero-chevron-left"}
                ]
              }
              phx-click="step"
              phx-value-direction={direction}
              aria-label={label}
              title={label <> " saved checkpoint"}
              disabled={!@playable || @data.revision <= @data.checkpoints.first}
              class="playback-step"
            ><.icon name={icon} class="size-5" /></button>
            <button
              id="play-toggle"
              phx-click="toggle_playback"
              disabled={!@playable || @data.checkpoints.count < 2}
              class="playback-toggle"
            ><.icon
              name={
                cond do
                  @playing -> "hero-pause-solid"
                  @data.revision == @data.checkpoints.last -> "hero-arrow-path"
                  true -> "hero-play-solid"
                end
              }
              class="size-4"
            />{cond do
              @playing -> "Pause"
              @data.revision == @data.checkpoints.last -> "Restart"
              true -> "Play"
            end}</button>
            <button
              :for={
                {direction, label, icon} <- [
                  {"next", "Next", "hero-chevron-right"},
                  {"last", "Last", "hero-forward"}
                ]
              }
              phx-click="step"
              phx-value-direction={direction}
              aria-label={label}
              title={label <> " saved checkpoint"}
              disabled={!@playable || @data.revision >= @data.checkpoints.last}
              class="playback-step"
            ><.icon name={icon} class="size-5" /></button>
          </div>
          <form id="checkpoint-seek" phx-change="seek">
            <label for="checkpoint-range" class="text-xs text-stone-600">Saved checkpoint · {@data.checkpoints.count} available</label>
            <input
              id="checkpoint-range"
              type="range"
              name="checkpoint"
              min="0"
              max={max(@data.checkpoints.count - 1, 0)}
              step="1"
              value={min(@data.checkpoint_index, max(@data.checkpoints.count - 1, 0))}
              phx-patch-focused
              aria-valuetext={
                if @data.snapshot,
                  do: "Saved revision #{@data.revision}",
                  else: "Snapshot unavailable"
              }
              disabled={!@playable || @data.checkpoints.count < 2}
              class="block min-h-11 w-full"
            />
          </form>
          <form id="playback-speed" phx-change="speed" class="playback-speed">
            <label for="checkpoint-speed" class="text-sm">Speed</label>
            <select
              id="checkpoint-speed"
              name="speed"
              class="min-h-11 rounded-md border-stone-300 text-sm"
              disabled={!@playable}
            >
              <option :for={speed <- ~w(0.5 1 2 4)} value={speed} selected={@speed == speed}>
                {speed}×
              </option>
            </select>
          </form>
        </div>
        <p class="text-xs leading-5 text-stone-500">
          Checkpoint cadence: 1× = one saved checkpoint per second, not original elapsed time. Each scrubber position selects a saved checkpoint; missing revisions are skipped. Read-only; no engine rules are rerun.
        </p>
        <p :if={@data.selected} class="mt-2 text-xs text-stone-600">
          Observed {utc(@data.selected.occurred_at)} · {@data.selected.payload["kind"]}
          <span :if={@data.selected.payload["action"]}> · {event_actor(
            @data.selected.payload["position"],
            @data
          )}: {Presentation.describe(@data.selected.payload["action"])}</span>
        </p>
      </div>
      <p
        :if={@notice}
        id="playback-notice"
        role="status"
        class="rounded-md border border-amber-200 bg-amber-50 px-4 py-3 text-sm"
      >
        {@notice}
      </p>
      <details class="rounded-lg border border-stone-200 bg-white p-4">
        <summary class="min-h-11 cursor-pointer py-3 font-medium">
          Exact revision and saved JSON evidence (private admin data)
        </summary>
        <form
          method="get"
          action={~p"/admin/history/#{@data.archive.game_instance_id}"}
          class="my-3 flex flex-wrap items-end gap-3"
        >
          <label class="text-sm">Exact revision<input
            type="number"
            min="0"
            name="revision"
            value={@data.revision}
            class="block min-h-11 w-32 rounded border-stone-300"
            required
          /></label>
          <button class="min-h-11 rounded-md border px-3 text-sm">Jump to saved revision</button>
          <.link
            patch={~p"/admin/history/#{@data.archive.game_instance_id}"}
            class="inline-flex min-h-11 items-center px-3 text-sm underline"
          >Latest</.link>
          <.link
            patch={
              ~p"/admin/history/#{@data.archive.game_instance_id}?#{%{revision: @data.revision}}"
            }
            class="inline-flex min-h-11 items-center px-3 text-sm underline"
          >Link to this revision</.link>
        </form>
        <pre :if={@data.snapshot} class="max-h-96 overflow-auto whitespace-pre-wrap break-all text-xs">{Jason.encode!(@data.snapshot, pretty: true)}</pre>
      </details>
    </section>
    """
  end

  defp report(assigns) do
    ~H"""
    <%= if @data.report do %>
      <section class="space-y-3 rounded-lg border bg-white p-4">
        <h2 class="break-all font-semibold">Report {@data.report.id}</h2>
        <p>Received by server {utc(@data.report.inserted_at)}</p>
        <p class="break-all">
          Room {@data.report.room_code} · Instance {@data.report.game_instance_id}
        </p>
        <p>
          Client claims: version {@data.report.app_version} · Build {@data.report.build} · {@data.report.platform}
        </p>
        <div class="flex flex-wrap gap-4 text-sm underline">
          <.link navigate={~p"/admin/users/#{@data.report.user_id}"}>Reporting user {@data.report.user_id}</.link>
          <.link navigate={~p"/admin/history/#{@data.report.game_instance_id}"}>Exact archived instance</.link>
        </div>
      </section>
      <section class="rounded-lg border border-amber-200 bg-amber-50 p-4">
        <h2 class="font-semibold">Authoritative archive context</h2>
        <%= if @data.archive && @data.archive.room_code == @data.report.room_code do %>
          <p>
            {outcome(@data.archive.status)} · {evidence(@data.archive.evidence_status)} · Last saved revision {@data.archive.last_revision} at {utc(
              @data.archive.saved_at
            )}
          </p>
        <% else %>
          <p>
            No matching retained archive. A client report is not a server replay or proof the action applied.
          </p>
        <% end %>
      </section>
      <section class="rounded-lg border bg-white p-4">
        <h2 class="text-lg font-semibold">Client-reported timeline · Unverified claims</h2>
        <p class="mt-1 text-sm text-stone-500">
          Offsets are relative to the first retained client event, not UTC timestamps. Report order is preserved; a timeout does not prove server rejection.
        </p>
        <ol id="client-timeline" class="mt-4 space-y-3">
          <li
            :for={event <- @data.report.events}
            class="break-words border-l-2 border-amber-300 pl-4 text-sm"
          >
            <strong>+{event["offset_ms"]} ms · {event["type"]}</strong>
            · {event["action"]} · {event["code"]}
            <p :if={event["action_id"]} class="break-all text-xs">Action ID {event["action_id"]}</p>
            <p :if={event["state_revision"]} class="text-xs">
              Claimed revision {event["state_revision"]} ·
              <.link
                navigate={
                  ~p"/admin/history/#{@data.report.game_instance_id}?#{%{revision: event["state_revision"]}}"
                }
                class="underline"
              >Inspect matching server checkpoint</.link>
            </p>
          </li>
        </ol>
      </section>
    <% else %>
      <.empty_state
        title="Report not found"
        body="This report ID is invalid, absent or expired. No client evidence is available."
      />
    <% end %>
    """
  end

  defp summary(assigns) do
    ~H"""
    <%= if @data.summary do %>
      <section class="space-y-3 rounded-lg border bg-white p-4">
        <h2 class="font-semibold">Completed · Summary-only record</h2>
        <p>No table or timeline is inferred from statistics. This is not a replay.</p>
        <p class="break-all">
          Summary {@data.summary.id} · Room {@data.summary.room_code} · {utc(
            @data.summary.completed_at
          )}
        </p>
        <p>
          Winner: {@data.summary.winner || "Not recorded"} · Scores: {Presentation.describe(
            @data.summary.final_scores
          )}
        </p>
        <p>
          Bid: {@data.summary.bid_amount || "Not recorded"} · Duration: {@data.summary.duration_seconds ||
            "Unknown"} seconds
        </p>
        <.link
          :if={@data.summary.game_instance_id}
          navigate={~p"/admin/history/#{@data.summary.game_instance_id}"}
          class="inline-block break-all underline"
        >Check exact archive {@data.summary.game_instance_id}</.link>
        <p :if={!@data.summary.game_instance_id}>
          No instance ID was recorded. A reused room code cannot safely link this summary to an archive or report.
        </p>
        <p :for={id <- @data.summary.player_ids || []}>
          <.link navigate={~p"/admin/users/#{id}"} class="break-all underline">Player {id}</.link>
        </p>
      </section>
    <% else %>
      <.empty_state title="Summary not found" body="No completed summary exists with this record ID." />
    <% end %>
    """
  end

  defp title(action) when action in [:reports, :report], do: "Incident reports"
  defp title(action) when action in [:summaries, :summary], do: "Completed summaries"
  defp title(_), do: "Game history"
  defp list_path(:reports), do: ~p"/admin/reports"
  defp list_path(:summaries), do: ~p"/admin/history/summaries"
  defp list_path(_), do: ~p"/admin/history"
  defp detail_path(:reports, row), do: ~p"/admin/reports/#{row.id}"
  defp detail_path(:summaries, row), do: ~p"/admin/history/summaries/#{row.id}"
  defp detail_path(_, row), do: ~p"/admin/history/#{row.game_instance_id}"

  defp query_path(path, params),
    do:
      path <>
        "?" <> URI.encode_query(Map.reject(params, fn {_key, value} -> value in [nil, ""] end))

  defp row_label(:reports, _), do: "Client-reported"
  defp row_label(:summaries, _), do: "Completed · Summary-only"
  defp row_time(:archives, row), do: "Started " <> utc(row.started_at)
  defp row_time(:reports, row), do: "Received " <> utc(row.inserted_at)
  defp row_time(:summaries, row), do: "Completed " <> utc(row.completed_at)
  defp outcome("active"), do: "Live / unclosed"
  defp outcome("complete"), do: "Completed"
  defp outcome("closed"), do: "Abandoned / closed"
  defp outcome("interrupted"), do: "Interrupted"
  defp outcome(value), do: value
  defp evidence("partial"), do: "Partial archive"
  defp evidence("uncertain"), do: "Uncertain archive"
  defp evidence("continuous"), do: "Continuous saved revisions"
  defp evidence(value), do: value
  defp utc(nil), do: "Not recorded"
  defp utc(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S") <> " UTC"
  defp utc(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S") <> " UTC"
  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.dump(value))

  defp event_actor(nil, _), do: "Server"

  defp event_actor(position, data),
    do:
      position <>
        " (initial seat: " <>
        Presentation.participant_name(data.archive.participants[position] || %{}, data.names) <>
        ")"

  defp list_notice(:archives),
    do:
      "Initial roster · current names and avatars, not historical snapshots. Each rematch is a separate instance. Archives start at deployment; older games are not backfilled."

  defp list_notice(:reports),
    do:
      "Private, bounded client claims. Search by exact identifiers; server receipt time is authoritative, client offsets are not."

  defp list_notice(:summaries),
    do:
      "Completed statistics, including pre-archive games. Summary-only does not imply a table, timeline or replay exists. Time filters use completion time."
end

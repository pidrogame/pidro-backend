defmodule PidroServerWeb.Dev.GameSettingsLive do
  @moduledoc "Runtime game pacing controls for the ops panel."

  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Games.{PacingSettings, RoomManager}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Game Settings")
     |> assign(:watching_tables, RoomManager.watching_tables?())
     |> assign_pacing_settings()}
  end

  @impl true
  def handle_event("update_pacing_form", %{"pacing" => params}, socket) do
    {:noreply, assign_pacing_settings(socket, PacingSettings.normalize_form(params))}
  end

  @impl true
  def handle_event("save_pacing", %{"pacing" => params}, socket) do
    case PacingSettings.validate(params) do
      {:ok, values} ->
        PacingSettings.save(values)

        {:noreply,
         socket
         |> assign_pacing_settings(PacingSettings.current_form())
         |> put_flash(:info, "Game pacing updated")}

      {:error, form, errors} ->
        {:noreply,
         socket
         |> assign_pacing_settings(form, errors)
         |> put_flash(:error, "Fix the pacing values and try again")}
    end
  end

  @impl true
  def handle_event("reset_pacing", _params, socket) do
    PacingSettings.reset()

    {:noreply,
     socket
     |> assign_pacing_settings(PacingSettings.current_form())
     |> put_flash(:info, "Game pacing reset to defaults")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="game-settings"
      title="Game settings"
      flash={@flash}
    >
      <section class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
        <h2 class="text-base font-semibold text-stone-950">Game Pacing</h2>
        <p class="mt-1 text-sm text-stone-600">
          Bot delays and trick/hand pauses apply immediately. A server restart restores the configured defaults.
        </p>
        <p class="mt-4 text-sm text-stone-600">
          <span class="font-semibold text-stone-950">
            Bots will act between {@pacing_preview.bot_delay_min_ms}ms and {@pacing_preview.bot_delay_max_ms}ms
          </span>
          · Trick pause: {@pacing_form["trick_transition_delay_ms"]}ms
          · Hand pause: {@pacing_form["hand_transition_delay_ms"]}ms
          · Deal pause: {@pacing_form["deal_transition_delay_ms"]}ms
        </p>
        <form
          id="pacing-form"
          phx-submit="save_pacing"
          phx-change="update_pacing_form"
          class="mt-6 space-y-6"
        >
          <div class="grid grid-cols-1 gap-6 md:grid-cols-2 xl:grid-cols-3">
            <div :for={field <- @pacing_fields}>
              <label for={pacing_input_id(field)} class="block text-sm font-medium">{field.label}</label>
              <p class="mt-1 text-xs text-stone-600">{field.description}</p>
              <input
                type="number"
                min={field.min}
                max={field.max}
                step={field.step}
                id={pacing_input_id(field)}
                name={"pacing[#{field_key(field)}]"}
                value={@pacing_form[field_key(field)]}
                class="mt-2 block w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-sm tabular-nums"
              />
              <p class="mt-1 flex justify-between text-xs text-stone-600">
                <span>Range: {field.min}ms to {field.max}ms</span>
                <span>Step: {field.step}ms</span>
              </p>
              <p :if={@pacing_errors[field_key(field)]} class="mt-1 text-xs font-medium text-red-700">
                {@pacing_errors[field_key(field)]}
              </p>
            </div>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              type="submit"
              class="rounded-md bg-stone-950 px-3 py-2 text-sm font-medium text-white hover:bg-stone-800"
            >Save Pacing</button>
            <button
              type="button"
              phx-click="reset_pacing"
              class="rounded-md border border-stone-300 bg-white px-3 py-2 text-sm font-medium text-stone-800 hover:bg-stone-100"
            >Reset to Defaults</button>
          </div>
        </form>
      </section>
      <section
        id="watching-tables"
        class="mt-6 rounded-lg border border-stone-200 bg-white p-4 sm:p-6"
      >
        <div class="flex items-center justify-between gap-4">
          <h2 class="text-base font-semibold text-stone-950">Watching tables</h2>
          <span
            id="watching-tables-state"
            class={[
              "rounded-full px-2.5 py-0.5 text-xs font-semibold",
              if(@watching_tables,
                do: "bg-emerald-100 text-emerald-800",
                else: "bg-stone-100 text-stone-700"
              )
            ]}
          >
            {if @watching_tables, do: "On", else: "Off"}
          </span>
        </div>
        <p class="mt-1 text-sm text-stone-600">
          On, the lobby lists playing tables to watch and anyone can join one as a spectator.
          Off, no table is listed to watch and Watch is refused.
        </p>
        <p class="mt-2 text-xs text-stone-600">
          Set <code>WATCHING_TABLES</code> in config/deploy.yml; the next deploy applies it.
        </p>
      </section>
    </.admin_shell>
    """
  end

  defp assign_pacing_settings(socket, form \\ nil, errors \\ %{}) do
    form = form || PacingSettings.current_form()

    socket
    |> assign(:pacing_fields, PacingSettings.field_specs())
    |> assign(:pacing_form, form)
    |> assign(:pacing_errors, errors)
    |> assign(:pacing_preview, PacingSettings.preview(form))
  end

  defp pacing_input_id(field), do: "pacing_#{field_key(field)}"
  defp field_key(field), do: Atom.to_string(field.key)
end

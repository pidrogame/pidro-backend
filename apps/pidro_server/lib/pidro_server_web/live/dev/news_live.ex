defmodule PidroServerWeb.Dev.NewsLive do
  @moduledoc """
  News posts (PID-346): write them in English and Swedish, preview them as
  the app shows them, publish them to every player. Data from
  `PidroServer.News`. The Swedish can be drafted from the English with
  `PidroServer.Translate` (PID-349); nothing is saved until Save.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.News
  alias PidroServer.News.Post
  alias PidroServer.Translate

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "News", post: nil, form: nil, preview: "en")
     |> assign(translate?: Translate.enabled?(), translating: false, translate_error: nil)
     |> load()}
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, edit(socket, %Post{})}

  def handle_event("edit", %{"id" => id}, socket), do: {:noreply, edit(socket, News.get!(id))}

  def handle_event("close", _params, socket),
    do: {:noreply, socket |> stop_translating() |> assign(post: nil, form: nil)}

  def handle_event("preview", %{"locale" => locale}, socket) when locale in ~w(en sv),
    do: {:noreply, assign(socket, preview: locale)}

  def handle_event("validate", %{"post" => params}, socket) do
    form =
      socket.assigns.post
      |> News.change(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"post" => params}, socket) do
    result =
      case socket.assigns.post do
        %Post{id: nil} -> News.create(params)
        post -> News.update(post, params)
      end

    case result do
      {:ok, post} ->
        {:noreply, socket |> edit(post) |> load() |> put_flash(:info, "Saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("translate", _params, socket) do
    english = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    {:noreply,
     socket
     |> assign(translating: true, translate_error: nil)
     |> start_async(:translate, fn ->
       Translate.to_swedish(english.title_en, english.body_en)
     end)}
  end

  def handle_event(action, %{"id" => id}, socket)
      when action in ~w(publish unpublish delete) do
    case run(action, News.get!(id)) do
      {:ok, post} -> {:noreply, socket |> follow(action, post) |> load()}
      {:error, :published} -> {:noreply, put_flash(socket, :error, "That post is published.")}
    end
  end

  @impl true
  def handle_async(:translate, {:ok, {:ok, swedish}}, socket) do
    %{post: post, form: form} = socket.assigns
    params = Map.merge(form.params, %{"title_sv" => swedish.title, "body_sv" => swedish.body})
    {:noreply, assign(socket, translating: false, form: to_form(News.change(post, params)))}
  end

  def handle_async(:translate, _failed, socket) do
    {:noreply,
     assign(socket, translating: false, translate_error: "Translation failed. Try again.")}
  end

  defp run("publish", post), do: News.publish(post)
  defp run("unpublish", post), do: News.unpublish(post)
  defp run("delete", post), do: News.delete(post)

  # The open editor follows its post, keeping what was typed and not saved.
  defp follow(%{assigns: %{post: %Post{id: id}}} = socket, "delete", %Post{id: id}),
    do: assign(socket, post: nil, form: nil)

  defp follow(
         %{assigns: %{post: %Post{id: id}, form: form}} = socket,
         _action,
         %Post{id: id} = post
       ),
       do: assign(socket, post: post, form: to_form(News.change(post, form.params)))

  defp follow(socket, _action, _post), do: socket

  defp edit(socket, post),
    do: socket |> stop_translating() |> assign(post: post, form: to_form(News.change(post)))

  # A translation running for the post that was open is dropped.
  defp stop_translating(socket),
    do:
      socket
      |> cancel_async(:translate)
      |> assign(translating: false, translate_error: nil)

  defp load(socket), do: assign(socket, posts: News.list_all())

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="news"
      title="News"
      subtitle="Posts every player reads on Home, in English or Swedish. A published post shows at once, with a dot until the player opens News."
      flash={@flash}
    >
      <:actions>
        <button
          type="button"
          phx-click="new"
          class="rounded-md bg-stone-950 px-3 py-1.5 text-sm font-semibold text-white hover:bg-stone-800"
        >
          New post
        </button>
      </:actions>

      <section id="news-posts" class="overflow-hidden rounded-lg border border-stone-200 bg-white">
        <p :if={@posts == []} class="px-4 py-6 text-sm text-stone-500">No posts yet.</p>
        <article
          :for={post <- @posts}
          id={"post-#{post.id}"}
          class="flex flex-col gap-3 border-b border-stone-100 px-4 py-3 last:border-b-0 lg:flex-row lg:items-center"
        >
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-semibold text-stone-950">{post.title_en}</p>
            <p class="mt-0.5 text-xs text-stone-500">
              <span
                :if={!post.published_at}
                class="rounded bg-amber-50 px-1.5 py-0.5 font-medium text-amber-800"
              >
                Draft
              </span>
              <span
                :if={post.published_at}
                class="rounded bg-emerald-50 px-1.5 py-0.5 font-medium text-emerald-800"
              >
                Published {Calendar.strftime(post.published_at, "%Y-%m-%d %H:%M")} UTC
              </span>
            </p>
          </div>
          <.link
            navigate={~p"/admin/feedback?#{[status: "all"]}"}
            class="text-sm text-stone-600 underline"
          >
            {answers(post.answers)}
          </.link>
          <div class="flex shrink-0 gap-2">
            <button type="button" phx-click="edit" phx-value-id={post.id} class={button()}>
              Edit
            </button>
            <button
              :if={!post.published_at}
              type="button"
              phx-click="publish"
              phx-value-id={post.id}
              data-confirm={"Publish “#{post.title_en}”? Every player sees it at once."}
              class="rounded-md bg-stone-950 px-3 py-1.5 text-sm font-semibold text-white hover:bg-stone-800"
            >
              Publish
            </button>
            <button
              :if={post.published_at}
              type="button"
              phx-click="unpublish"
              phx-value-id={post.id}
              class={button()}
            >
              Unpublish
            </button>
            <button
              :if={!post.published_at}
              type="button"
              phx-click="delete"
              phx-value-id={post.id}
              data-confirm={"Delete the draft “#{post.title_en}”?"}
              class="rounded-md border border-rose-200 bg-white px-3 py-1.5 text-sm font-semibold text-rose-700 hover:bg-rose-50"
            >
              Delete
            </button>
          </div>
        </article>
      </section>

      <section
        :if={@form}
        id="news-editor"
        class="flex flex-col gap-6 rounded-lg border border-stone-200 bg-white p-5 lg:flex-row"
      >
        <.form
          for={@form}
          id="news-form"
          phx-change="validate"
          phx-submit="save"
          class="min-w-0 flex-1 space-y-3"
        >
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold">
              {if @post.id, do: "Edit post", else: "New post"}
            </h2>
            <button type="button" phx-click="close" class="text-sm text-stone-600 underline">
              Close
            </button>
          </div>
          <.input field={@form[:title_en]} label="English title" maxlength="200" required />
          <.input
            field={@form[:body_en]}
            type="textarea"
            label="English body"
            rows="6"
            maxlength="5000"
            required
          />
          <div class="flex items-center justify-between gap-3 border-t border-stone-100 pt-3">
            <p class="text-sm font-semibold text-stone-800">Swedish</p>
            <button
              type="button"
              id="translate"
              phx-click="translate"
              disabled={
                !@translate? or @translating or blank?(@form[:title_en].value) or
                  blank?(@form[:body_en].value)
              }
              data-confirm={
                if !blank?(@form[:title_sv].value) or !blank?(@form[:body_sv].value),
                  do: "Replace the Swedish text with a new translation?"
              }
              class="inline-flex items-center gap-2 rounded-md border border-stone-300 bg-white px-3 py-1.5 text-sm font-semibold text-stone-700 hover:text-stone-950 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <.icon :if={@translating} name="hero-arrow-path" class="size-4 animate-spin" />
              {if @translating, do: "Translating…", else: "Translate to Swedish"}
            </button>
          </div>
          <p :if={!@translate?} id="translate-off" class="text-xs text-stone-500">
            Add ANTHROPIC_API_KEY to turn on translation.
          </p>
          <p :if={@translate_error} id="translate-error" class="text-sm text-rose-700">
            {@translate_error}
          </p>
          <.input field={@form[:title_sv]} label="Swedish title" maxlength="200" />
          <.input
            field={@form[:body_sv]}
            type="textarea"
            label="Swedish body"
            rows="6"
            maxlength="5000"
          />
          <p class="text-xs text-stone-500">
            Plain text; line breaks are kept. An empty Swedish field falls back to English.
          </p>
          <button class="rounded-md bg-stone-950 px-4 py-2 font-semibold text-white hover:bg-stone-800">
            Save
          </button>
        </.form>

        <div class="w-full shrink-0 lg:w-[390px]">
          <div class="mb-2 flex items-center justify-between">
            <p class="text-xs font-medium text-stone-500">In the app</p>
            <nav class="flex gap-1 text-sm" aria-label="Preview language">
              <button
                :for={{locale, label} <- [{"en", "English"}, {"sv", "Swedish"}]}
                type="button"
                phx-click="preview"
                phx-value-locale={locale}
                class={[
                  "rounded-md px-2.5 py-1 font-medium",
                  if(@preview == locale,
                    do: "bg-stone-950 text-white",
                    else: "text-stone-600 hover:text-stone-950"
                  )
                ]}
              >
                {label}
              </button>
            </nav>
          </div>
          <.preview post={Ecto.Changeset.apply_changes(@form.source)} locale={@preview} />
        </div>
      </section>
    </.admin_shell>
    """
  end

  attr :post, Post, required: true
  attr :locale, :string, required: true

  defp preview(assigns) do
    assigns = assign(assigns, shown: News.localize(assigns.post, assigns.locale))

    ~H"""
    <article
      id="news-preview"
      class="w-full max-w-[390px] rounded-2xl bg-[#1c1f24] p-5 text-white shadow-lg"
    >
      <p class="text-xs uppercase tracking-wide text-white/50">
        {Calendar.strftime(@post.published_at || DateTime.utc_now(), "%-d %b %Y")}
      </p>
      <h3 class="mt-2 text-lg font-bold leading-snug">{@shown.title || "Title"}</h3>
      <p phx-no-format class="mt-2 whitespace-pre-wrap text-[15px] leading-6 text-white/85">{@shown.body || "Body"}</p>
    </article>
    """
  end

  defp button,
    do:
      "rounded-md border border-stone-300 bg-white px-3 py-1.5 text-sm font-semibold text-stone-700 hover:text-stone-950"

  defp blank?(value), do: value in [nil, ""] or String.trim(value) == ""

  defp answers(1), do: "1 answer"
  defp answers(n), do: "#{n} answers"
end

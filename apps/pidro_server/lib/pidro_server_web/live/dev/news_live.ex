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
  alias PidroServer.StoreBuilds
  alias PidroServer.StoreBuilds.Cache
  alias PidroServer.Translate

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Cache.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: "News",
       stores: Cache.snapshot(),
       post: nil,
       form: nil,
       preview: "en",
       preview_mode: "card",
       preview_platform: "android"
     )
     |> assign(translate?: Translate.enabled?(), translating: false, translate_error: nil)
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png),
       max_entries: 1,
       max_file_size: 5 * 1024 * 1024
     )
     |> load()}
  end

  @impl true
  def handle_params(%{"app_update" => "true"}, _uri, socket) do
    post = %Post{app_update: true}

    params =
      StoreBuilds.live_versions(
        socket.assigns.stores,
        News.native_update_policy().minimum_native_versions
      )

    {:noreply, socket |> edit(post) |> assign(form: to_form(News.change(post, params)))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:store_builds, stores}, socket), do: {:noreply, assign(socket, stores: stores)}

  @impl true
  def handle_event("refresh_store", %{"platform" => platform}, socket)
      when platform in ~w(ios android) do
    Cache.refresh(platform)
    {:noreply, socket}
  end

  def handle_event("new", _params, socket), do: {:noreply, edit(socket, %Post{})}

  def handle_event("edit", %{"id" => id}, socket), do: {:noreply, edit(socket, News.get!(id))}

  def handle_event("close", _params, socket),
    do: {:noreply, socket |> stop_translating() |> assign(post: nil, form: nil)}

  def handle_event("preview", %{"locale" => locale}, socket) when locale in ~w(en sv),
    do: {:noreply, assign(socket, preview: locale)}

  def handle_event("preview_mode", %{"mode" => mode}, socket) when mode in ~w(card popup),
    do: {:noreply, assign(socket, preview_mode: mode)}

  def handle_event("preview_platform", %{"platform" => platform}, socket)
      when platform in ~w(android ios),
      do: {:noreply, assign(socket, preview_platform: platform)}

  def handle_event("cancel_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :image, ref)}

  def handle_event("remove_image", _params, socket) do
    {:ok, post} = News.remove_image(socket.assigns.post)

    {:noreply,
     assign(socket, post: post, form: to_form(News.change(post, socket.assigns.form.params)))}
  end

  def handle_event("validate", %{"post" => params}, socket) do
    params = form_params(socket, params)

    form =
      socket.assigns.post
      |> News.change(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"post" => params}, socket) do
    params = form_params(socket, params)

    result =
      case socket.assigns.post do
        %Post{id: nil} -> News.create(params)
        post -> News.update(post, params)
      end

    case result do
      {:ok, post} ->
        images =
          consume_uploaded_entries(socket, :image, fn %{path: path}, _entry ->
            {:ok, News.put_image(post, %Plug.Upload{path: path})}
          end)

        post = News.get!(post.id)

        socket =
          socket
          |> stop_translating()
          |> assign(post: post, form: to_form(News.change(post)))
          |> load()

        case images do
          [{:error, _reason}] ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "Text saved, but the image could not be processed. Choose a PNG or JPEG up to 5 MiB and 16 megapixels."
             )}

          _ ->
            {:noreply, put_flash(socket, :info, "Saved.")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("translate", _params, socket) do
    english = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    extra =
      Map.reject(%{eyebrow: english.eyebrow_en, button_label: english.button_label_en}, fn {_key,
                                                                                            value} ->
        blank?(value)
      end)

    {:noreply,
     socket
     |> assign(translating: true, translate_error: nil)
     |> start_async(:translate, fn ->
       Translate.to_swedish(english.title_en, english.body_en, extra)
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

    params =
      Map.merge(form.params, Map.new(swedish, fn {field, value} -> {"#{field}_sv", value} end))

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

  defp edit(socket, post) do
    socket =
      Enum.reduce(socket.assigns.uploads.image.entries, socket, fn entry, socket ->
        cancel_upload(socket, :image, entry.ref)
      end)

    socket |> stop_translating() |> assign(post: post, form: to_form(News.change(post)))
  end

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
        <p :if={@posts == []} class="px-4 py-6 text-sm text-stone-600">No posts yet.</p>
        <article
          :for={post <- @posts}
          id={"post-#{post.id}"}
          class="flex flex-col gap-3 border-b border-stone-100 px-4 py-3 last:border-b-0 lg:flex-row lg:items-center"
        >
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-semibold text-stone-950">{post.title_en}</p>
            <p class="mt-0.5 text-xs text-stone-600">
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
            <h2 class="text-base font-semibold">
              {if @post.id, do: "Edit post", else: "New post"}
            </h2>
            <button type="button" phx-click="close" class="text-sm text-stone-600 underline">
              Close
            </button>
          </div>
          <.input field={@form[:eyebrow_en]} label="English eyebrow (optional)" maxlength="200" />
          <.input field={@form[:title_en]} label="English title" maxlength="200" required />
          <.input
            field={@form[:body_en]}
            type="textarea"
            label="English body"
            rows="6"
            maxlength="5000"
            required
          />
          <p class="text-xs text-stone-600">
            Markdown: **bold**, line breaks and [links](https://…). Nothing else.
          </p>
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
                if Enum.any?(
                     [:title_sv, :body_sv, :eyebrow_sv, :button_label_sv],
                     &(!blank?(@form[&1].value))
                   ),
                   do: "Replace the Swedish text with a new translation?"
              }
              class="inline-flex items-center gap-2 rounded-md border border-stone-300 bg-white px-3 py-1.5 text-sm font-semibold text-stone-700 hover:text-stone-950 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <.icon :if={@translating} name="hero-arrow-path" class="size-4 animate-spin" />
              {if @translating, do: "Translating…", else: "Translate to Swedish"}
            </button>
          </div>
          <p :if={!@translate?} id="translate-off" class="text-xs text-stone-600">
            Add ANTHROPIC_API_KEY to turn on translation.
          </p>
          <p :if={@translate_error} id="translate-error" class="text-sm text-rose-700">
            {@translate_error}
          </p>
          <.input field={@form[:eyebrow_sv]} label="Swedish eyebrow (optional)" maxlength="200" />
          <.input field={@form[:title_sv]} label="Swedish title" maxlength="200" />
          <.input
            field={@form[:body_sv]}
            type="textarea"
            label="Swedish body"
            rows="6"
            maxlength="5000"
          />
          <p class="text-xs text-stone-600">
            Markdown: **bold**, line breaks and [links](https://…). An empty Swedish field falls back to English.
          </p>
          <div class="space-y-3 border-t border-stone-100 pt-3">
            <label for={@uploads.image.ref} class="block text-sm font-semibold text-stone-800">Image (optional)</label>
            <.live_file_input
              upload={@uploads.image}
              class="block w-full min-w-0 text-sm text-stone-600"
            />
            <p class="text-xs text-stone-600">
              Upload PNG or JPEG, up to 5 MiB. Stored on this server, resized without cropping.
            </p>
            <div :for={entry <- @uploads.image.entries} class="space-y-2">
              <p class="text-sm text-stone-600">{entry.client_name}</p>
              <button
                type="button"
                phx-click="cancel_image"
                phx-value-ref={entry.ref}
                class="text-sm underline"
              >Cancel image</button>
              <p :for={error <- upload_errors(@uploads.image, entry)} class="text-sm text-rose-700">
                {upload_error(error)}
              </p>
            </div>
            <p :for={error <- upload_errors(@uploads.image)} class="text-sm text-rose-700">
              {upload_error(error)}
            </p>
            <div :if={@post.image_version} class="flex items-center gap-3">
              <img
                src={News.image_url(@post)}
                alt="Current post image"
                class="max-h-24 max-w-40 rounded-lg"
              />
              <button type="button" phx-click="remove_image" class="text-sm underline">Remove image</button>
            </div>
          </div>
          <.input
            field={@form[:show_as_popup]}
            type="checkbox"
            role="switch"
            class="toggle toggle-sm"
            label="Show as pop-up"
          />
          <.input
            field={@form[:app_update]}
            type="checkbox"
            role="switch"
            class="toggle toggle-sm"
            label="App update"
          />
          <div :if={Ecto.Changeset.get_field(@form.source, :app_update)} class="space-y-3">
            <.input
              field={@form[:show_below_android]}
              label="Android: show below version"
              placeholder="3.2.4"
            />
            <.store_hint
              store={@stores["android"]}
              version={@form[:show_below_android].value}
              platform="android"
            />
            <.input
              field={@form[:show_below_ios]}
              label="iPhone: show below version"
              placeholder="3.2.4"
            />
            <.store_hint store={@stores["ios"]} version={@form[:show_below_ios].value} platform="ios" />
            <p class="text-xs text-stone-600">
              Empty = nobody on that platform. Set a version only when it is live in the store. The app supplies the Update button and the store link from server settings.
            </p>
          </div>
          <div :if={!Ecto.Changeset.get_field(@form.source, :app_update)} class="space-y-3">
            <.input
              field={@form[:button_label_en]}
              label="English button label (optional)"
              maxlength="100"
            />
            <.input
              field={@form[:button_label_sv]}
              label="Swedish button label (optional)"
              maxlength="100"
            />
            <.input
              field={@form[:button_url]}
              label="Button link (optional)"
              placeholder="https://… or pidro://…"
            />
            <p class="text-xs text-stone-600">
              Without a label and link the button says Got it / Okej.
            </p>
          </div>
          <p
            :if={hidden_errors?(@form.source)}
            id="hidden-settings-error"
            role="alert"
            class="text-sm text-rose-700"
          >
            Some hidden settings are invalid. Toggle App update to correct the highlighted fields, then save.
          </p>
          <button
            class="rounded-md bg-stone-950 px-4 py-2 font-semibold text-white hover:bg-stone-800"
            disabled={upload_errors(@uploads.image) != []}
          >
            Save
          </button>
        </.form>

        <div class="w-full shrink-0 lg:w-[390px]">
          <div class="mb-2 flex items-center justify-between">
            <p class="text-xs font-medium text-stone-600">In the app</p>
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
          <nav class="mb-3 flex flex-wrap gap-1 text-sm" aria-label="Preview mode">
            <button
              :for={{mode, label} <- [{"card", "News card"}, {"popup", "Pop-up"}]}
              type="button"
              phx-click="preview_mode"
              phx-value-mode={mode}
              aria-pressed={@preview_mode == mode}
              class={[
                "rounded-md px-2.5 py-1 font-medium",
                if(@preview_mode == mode,
                  do: "bg-stone-950 text-white",
                  else: "text-stone-600 hover:text-stone-950"
                )
              ]}
            >{label}</button>
          </nav>
          <nav
            :if={@preview_mode == "popup" and Ecto.Changeset.get_field(@form.source, :app_update)}
            class="mb-3 flex gap-1 text-sm"
            aria-label="Preview phone"
          >
            <button
              :for={{platform, label} <- [{"android", "Android"}, {"ios", "iPhone"}]}
              type="button"
              phx-click="preview_platform"
              phx-value-platform={platform}
              aria-pressed={@preview_platform == platform}
              class={[
                "rounded-md px-2.5 py-1",
                if(@preview_platform == platform,
                  do: "bg-stone-200 text-stone-950",
                  else: "text-stone-600"
                )
              ]}
            >{label}</button>
          </nav>
          <.preview
            post={Ecto.Changeset.apply_changes(@form.source)}
            locale={@preview}
            mode={@preview_mode}
            platform={@preview_platform}
            entries={@uploads.image.entries}
          />
        </div>
      </section>
    </.admin_shell>
    """
  end

  attr :store, :map, required: true
  attr :version, :any, required: true
  attr :platform, :string, required: true

  defp store_hint(assigns) do
    assigns = assign(assigns, live: get_in(assigns.store, [:data, :live, :version]))

    ~H"""
    <div id={"store-hint-#{@platform}"} class="text-xs leading-5 text-stone-600">
      <p>{StoreBuilds.hint(@store)}</p>
      <p :if={@store.checked_at}>
        Checked {Calendar.strftime(@store.checked_at, "%Y-%m-%d %H:%M UTC")}
      </p>
      <button
        type="button"
        phx-click="refresh_store"
        phx-value-platform={@platform}
        disabled={@store.refreshing}
        class="font-medium underline disabled:opacity-50"
      >
        {if @store.refreshing, do: "Checking…", else: "Refresh #{StoreBuilds.store_name(@platform)}"}
      </button>
      <p :if={@platform == "android"}>
        Uses the EAS submit account: don't refresh while an Android build is being submitted.
      </p>
      <p :if={StoreBuilds.above?(@version, @live)} role="alert" class="font-medium text-amber-800">
        Players would be sent to a store that doesn't have {@version} yet. This is a warning, not a block.
      </p>
      <p
        :if={@version not in [nil, ""] and is_nil(@live)}
        role="alert"
        class="font-medium text-amber-800"
      >
        The store has no confirmed live version. Verify {@version} in the console before publishing.
      </p>
    </div>
    """
  end

  attr :post, Post, required: true
  attr :locale, :string, required: true
  attr :mode, :string, required: true
  attr :platform, :string, required: true
  attr :entries, :list, default: []

  defp preview(assigns) do
    assigns = assign(assigns, shown: News.localize(assigns.post, assigns.locale))

    ~H"""
    <article
      id="news-preview"
      class={[
        "w-full max-w-[390px] break-words p-5 text-white shadow-lg",
        if(@mode == "popup",
          do: "rounded-3xl border border-[#8beaff]/30 bg-[#0b3563]",
          else: "rounded-2xl bg-[#1c1f24]"
        )
      ]}
    >
      <.live_img_preview
        :for={entry <- @entries}
        entry={entry}
        class="mb-4 max-h-48 w-full rounded-xl object-contain"
      />
      <img
        :if={@shown.image_url && @entries == []}
        src={@shown.image_url}
        alt="Post image"
        class="mb-4 max-h-48 w-full rounded-xl object-contain"
      />
      <p :if={@mode == "card"} class="text-xs uppercase tracking-wide text-white/50">
        {Calendar.strftime(@post.published_at || DateTime.utc_now(), "%-d %b %Y")}
      </p>
      <p :if={@shown.eyebrow} class="mt-2 text-xs font-bold uppercase tracking-wide text-[#FFD447]">
        {@shown.eyebrow}
      </p>
      <h3 class={[
        "mt-2 font-bold leading-snug",
        if(@mode == "popup", do: "font-serif text-3xl", else: "text-lg")
      ]}>
        {@shown.title || "Title"}
      </h3>
      <p phx-no-format class="mt-3 whitespace-pre-wrap text-[17px] leading-7 text-white/90">{markdown(@shown.body || "Body")}</p>
      <div :if={@mode == "popup"} class="mt-6 space-y-2">
        <div class="rounded-xl border border-amber-200/40 bg-[#8b5d32] px-3 py-4 text-center text-lg font-bold shadow-sm">
          {preview_button(@shown, @locale, @platform)}
        </div>
        <p :if={@shown.app_update} class="py-2 text-center font-semibold text-[#8beaff]">
          {if @locale == "sv", do: "Senare", else: "Later"}
        </p>
      </div>
    </article>
    """
  end

  defp preview_button(%{app_update: true}, locale, platform) do
    store = if platform == "ios", do: "App Store", else: "Google Play"
    if locale == "sv", do: "Uppdatera i #{store}", else: "Update in #{store}"
  end

  defp preview_button(post, locale, _platform) do
    if post.button_label && post.button_url,
      do: post.button_label,
      else: if(locale == "sv", do: "Okej", else: "Got it")
  end

  # Deliberately only bold and links. Escape all text, including unsupported HTML.
  defp markdown(text) do
    Regex.split(~r/(\*\*[^*]+\*\*|\[[^\]\n]+\]\([^\s)]+\))/, text, include_captures: true)
    |> Enum.map(fn token ->
      cond do
        String.starts_with?(token, "**") and String.ends_with?(token, "**") ->
          ["<strong>", escape(String.slice(token, 2..-3//1)), "</strong>"]

        String.starts_with?(token, "[") ->
          case Regex.run(~r/^\[([^\]]+)\]\(([^)]+)\)$/, token) do
            [_, label, url] ->
              if Post.safe_link?(url),
                do: [
                  "<a class=\"text-[#8beaff] underline\" href=\"",
                  escape(url),
                  "\">",
                  escape(label),
                  "</a>"
                ],
                else: escape(token)

            _ ->
              escape(token)
          end

        true ->
          escape(token)
      end
    end)
    |> Phoenix.HTML.raw()
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp form_params(socket, params) do
    previous =
      Map.reject(socket.assigns.form.params, fn {key, _} ->
        String.starts_with?(key, "_unused_")
      end)

    Map.merge(previous, params)
  end

  defp hidden_errors?(changeset) do
    fields =
      if Ecto.Changeset.get_field(changeset, :app_update),
        do: [:button_label_en, :button_label_sv, :button_url],
        else: [:show_below_android, :show_below_ios]

    Enum.any?(fields, &Keyword.has_key?(changeset.errors, &1))
  end

  defp upload_error(:too_large), do: "Image must be at most 5 MiB."
  defp upload_error(:not_accepted), do: "Choose a PNG or JPEG."
  defp upload_error(:too_many_files), do: "Choose one image."
  defp upload_error(_), do: "Image upload failed. Try again."

  defp button,
    do:
      "rounded-md border border-stone-300 bg-white px-3 py-1.5 text-sm font-semibold text-stone-700 hover:text-stone-950"

  defp blank?(value), do: value in [nil, ""] or String.trim(value) == ""

  defp answers(1), do: "1 answer"
  defp answers(n), do: "#{n} answers"
end

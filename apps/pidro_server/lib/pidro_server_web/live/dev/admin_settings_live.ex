defmodule PidroServerWeb.Dev.AdminSettingsLive do
  @moduledoc "Admin account management and change-own-password screen."

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Admins
  alias PidroServer.Admins.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admins")
     |> assign(:temporary_password, nil)
     |> assign(:temporary_password_email, nil)
     |> assign_admin_forms()
     |> load_admins()}
  end

  @impl true
  def handle_event("validate_admin", %{"admin" => params}, socket) do
    changeset =
      %Admin{}
      |> Admins.change_admin_email(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :admin_form, to_form(changeset, as: :admin))}
  end

  def handle_event("add_admin", %{"admin" => params}, socket) do
    case Admins.create_admin(socket.assigns.current_admin, params) do
      {:ok, admin, temporary_password} ->
        {:noreply,
         socket
         |> assign(:admin_form, to_form(Admins.change_admin_email(%Admin{}), as: :admin))
         |> assign(:temporary_password, temporary_password)
         |> assign(:temporary_password_email, admin.email)
         |> load_admins()
         |> put_flash(:info, "Admin added. Share the temporary password out of band.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:admin_form, to_form(Map.put(changeset, :action, :validate), as: :admin))
         |> put_flash(:error, "Could not add that admin.")}
    end
  end

  def handle_event("dismiss_temporary_password", _params, socket) do
    {:noreply,
     socket
     |> assign(:temporary_password, nil)
     |> assign(:temporary_password_email, nil)}
  end

  def handle_event("remove_admin", %{"id" => id}, socket) do
    current_admin = socket.assigns.current_admin

    case Admins.delete_admin(current_admin, id) do
      {:ok, %{id: deleted_id}} when deleted_id == current_admin.id ->
        {:noreply,
         socket
         |> put_flash(:info, "Your admin account was removed.")
         |> redirect(to: ~p"/admin/login")}

      {:ok, admin} ->
        {:noreply,
         socket
         |> load_admins()
         |> put_flash(:info, "Removed #{admin.email}.")}

      {:error, :last_admin} ->
        {:noreply, put_flash(socket, :error, "The last admin cannot remove themselves.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> load_admins()
         |> put_flash(:error, "That admin could not be removed.")}
    end
  end

  def handle_event("change_password", %{"admin" => params}, socket) do
    case Admins.update_admin_password(socket.assigns.current_admin, params) do
      {:ok, _admin} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password changed. Sign in again with your new password.")
         |> redirect(to: ~p"/admin/login")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:password_form, to_form(Map.put(changeset, :action, :validate), as: :admin))
         |> put_flash(:error, "Could not change your password.")}
    end
  end

  @impl true
  def render(%{current_admin: nil} = assigns) do
    ~H"""
    <.admin_shell active="admins" title="Admins" flash={@flash}>
      <div class="rounded-lg border border-stone-200 bg-white p-6 text-sm text-stone-600">
        Admin management requires an authenticated account. The rest of the ops panel is bypassed
        only because this server is running in local development.
      </div>
    </.admin_shell>
    """
  end

  def render(%{current_admin: %{force_password_change: true}} = assigns) do
    ~H"""
    <div class="min-h-screen bg-stone-50 px-4 py-12 text-stone-950 sm:px-6">
      <div class="mx-auto max-w-lg rounded-lg border border-amber-200 bg-white p-6 shadow-sm">
        <Layouts.flash_group flash={@flash} />
        <p class="text-xs font-semibold uppercase tracking-wide text-amber-700">Action required</p>
        <h1 class="mt-2 text-2xl font-semibold">Change your temporary password</h1>
        <p class="mt-2 text-sm leading-6 text-stone-600">
          You cannot open any ops view until you replace the password issued for {@current_admin.email}.
        </p>
        <.password_form form={@password_form} />
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <.admin_shell
      active="admins"
      title="Admins"
      flash={@flash}
    >
      <div class="grid gap-4 lg:grid-cols-2">
        <section class="rounded-lg border border-stone-200 bg-white p-5">
          <h2 class="text-base font-semibold">Change your password</h2>
          <p class="mt-1 text-sm text-stone-600">Changing it signs out all of your sessions.</p>
          <.password_form form={@password_form} />
        </section>

        <section class="rounded-lg border border-stone-200 bg-white p-5">
          <h2 class="text-base font-semibold">Add an admin</h2>
          <p class="mt-1 text-sm text-stone-600">
            A one-time temporary password is generated and shown only here.
          </p>
          <.form
            for={@admin_form}
            id="add-admin-form"
            phx-change="validate_admin"
            phx-submit="add_admin"
            class="mt-4"
          >
            <.input field={@admin_form[:email]} type="email" label="Email" required />
            <button class="mt-2 rounded-md bg-stone-950 px-4 py-2 text-sm font-semibold text-white">
              Add admin
            </button>
          </.form>
        </section>
      </div>

      <section
        :if={@temporary_password}
        class="rounded-lg border border-amber-300 bg-amber-50 p-5"
      >
        <h2 class="font-semibold text-amber-950">
          Temporary password for {@temporary_password_email}
        </h2>
        <p class="mt-1 text-sm text-amber-900">Copy it now. It is not stored in plaintext.</p>
        <code class="mt-3 block break-all rounded-md bg-white p-3 font-mono text-stone-950">
          {@temporary_password}
        </code>
        <button
          type="button"
          phx-click="dismiss_temporary_password"
          class="mt-3 text-sm font-semibold text-amber-950 underline"
        >
          I have copied it
        </button>
      </section>

      <section class="overflow-hidden rounded-lg border border-stone-200 bg-white">
        <div class="border-b border-stone-200 px-5 py-4">
          <h2 class="text-base font-semibold">Current admins</h2>
        </div>
        <ul class="divide-y divide-stone-200">
          <li :for={admin <- @admins} class="flex items-center justify-between gap-4 px-5 py-4">
            <div>
              <p class="font-medium text-stone-950">{admin.email}</p>
              <p :if={admin.force_password_change} class="text-xs text-amber-700">
                Must change temporary password
              </p>
            </div>
            <button
              type="button"
              phx-click="remove_admin"
              phx-value-id={admin.id}
              data-confirm={"Remove admin #{admin.email}? Their sessions will stop immediately."}
              class="text-sm font-semibold text-rose-700 hover:text-rose-900"
            >
              Remove
            </button>
          </li>
        </ul>
      </section>
    </.admin_shell>
    """
  end

  attr :form, :map, required: true

  defp password_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="change-admin-password-form"
      phx-submit="change_password"
      class="mt-4 space-y-3"
    >
      <.input
        field={@form[:current_password]}
        type="password"
        label="Current password"
        autocomplete="current-password"
        required
      />
      <.input
        field={@form[:password]}
        type="password"
        label="New password"
        autocomplete="new-password"
        required
      />
      <.input
        field={@form[:password_confirmation]}
        type="password"
        label="Confirm new password"
        autocomplete="new-password"
        required
      />
      <button class="rounded-md bg-stone-950 px-4 py-2 text-sm font-semibold text-white">
        Change password
      </button>
    </.form>
    """
  end

  defp assign_admin_forms(socket) do
    case socket.assigns.current_admin do
      nil ->
        socket
        |> assign(:password_form, nil)
        |> assign(:admin_form, nil)

      admin ->
        socket
        |> assign(:password_form, to_form(Admins.change_admin_password(admin), as: :admin))
        |> assign(:admin_form, to_form(Admins.change_admin_email(%Admin{}), as: :admin))
    end
  end

  defp load_admins(%{assigns: %{current_admin: nil}} = socket), do: assign(socket, :admins, [])
  defp load_admins(socket), do: assign(socket, :admins, Admins.list_admins())
end

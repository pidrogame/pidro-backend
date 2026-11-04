defmodule PidroServerWeb.AdminAuth do
  @moduledoc """
  Router and LiveView boundary authentication for the ops panel.
  """

  use PidroServerWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias PidroServer.Admins

  @mutating_events MapSet.new(~w(
    apply_bot_config
    assign_seat
    auto_bid
    confirm_delete
    create_game
    execute_action
    fast_forward
    new_template
    play_again
    play_card
    preset_1h_3b
    preset_2h_2b
    preset_4_bots
    preset_empty_room
    reset_pacing
    save
    save_pacing
    save_template
    send_test_email
    submit_hand_selection
    toggle_all_bots_pause
    toggle_bot_pause
    undo_last_action
  ))

  def log_in_admin(conn, admin) do
    token = Admins.generate_admin_session_token(admin)
    return_to = get_session(conn, :admin_return_to)

    conn
    |> renew_session()
    |> put_session(:admin_token, token)
    |> redirect(to: login_redirect(admin, return_to))
  end

  def log_out_admin(conn) do
    Admins.delete_admin_session_token(get_session(conn, :admin_token))

    conn
    |> renew_session()
    |> redirect(to: ~p"/admin/login")
  end

  def fetch_current_admin(conn, _opts) do
    admin =
      conn
      |> get_session(:admin_token)
      |> Admins.get_admin_by_session_token()

    assign(conn, :current_admin, admin)
  end

  def require_authenticated_admin(conn, _opts) do
    if local_bypass?() or conn.assigns.current_admin do
      conn
    else
      conn
      |> put_flash(:error, "You must sign in to access Pidro Ops.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/admin/login")
      |> halt()
    end
  end

  def require_changed_password(conn, _opts) do
    admin = conn.assigns.current_admin

    if local_bypass?() or is_nil(admin) or not admin.force_password_change do
      conn
    else
      conn
      |> put_flash(:error, "Change your temporary password before using Pidro Ops.")
      |> redirect(to: ~p"/admin/admins")
      |> halt()
    end
  end

  def redirect_if_admin_is_authenticated(conn, _opts) do
    if local_bypass?() or conn.assigns[:current_admin] do
      redirect(conn, to: ~p"/admin/dashboard") |> halt()
    else
      conn
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    mount_and_verify(socket, session, false)
  end

  def on_mount(:ensure_authenticated_and_password_changed, _params, session, socket) do
    mount_and_verify(socket, session, true)
  end

  defp mount_and_verify(socket, session, require_changed_password?) do
    token = session["admin_token"]

    socket =
      socket
      |> Component.assign(:admin_session_token, token)
      |> Component.assign(:current_admin, nil)

    case verify_live_admin(socket, require_changed_password?) do
      {:cont, socket} ->
        socket =
          LiveView.attach_hook(socket, :verify_admin_session, :handle_event, fn event,
                                                                                _params,
                                                                                socket ->
            case verify_live_admin(socket, require_changed_password?) do
              {:cont, socket} ->
                authorize_live_admin_event(socket, event)

              {:halt, socket} ->
                {:halt, socket}
            end
          end)

        {:cont, socket}

      {:halt, socket} ->
        {:halt, socket}
    end
  end

  defp verify_live_admin(socket, require_changed_password?) do
    if local_bypass?() do
      {:cont, Component.assign(socket, :current_admin, nil)}
    else
      admin = Admins.get_admin_by_session_token(socket.assigns.admin_session_token)
      socket = Component.assign(socket, :current_admin, admin)

      cond do
        is_nil(admin) ->
          {:halt,
           socket
           |> LiveView.put_flash(:error, "Your admin session is no longer valid.")
           |> LiveView.redirect(to: ~p"/admin/login")}

        require_changed_password? and admin.force_password_change ->
          {:halt,
           socket
           |> LiveView.put_flash(:error, "Change your temporary password before using Pidro Ops.")
           |> LiveView.redirect(to: ~p"/admin/admins")}

        true ->
          {:cont, socket}
      end
    end
  end

  defp authorize_live_admin_event(
         %{assigns: %{current_admin: %{force_password_change: true}}} = socket,
         event
       )
       when event != "change_password" do
    {:halt,
     LiveView.put_flash(
       socket,
       :error,
       "Change your temporary password before managing admins."
     )}
  end

  defp authorize_live_admin_event(socket, event) do
    log_mutation(socket.assigns.current_admin, event)
    {:cont, socket}
  end

  defp log_mutation(nil, event) do
    if MapSet.member?(@mutating_events, event) do
      require Logger
      Logger.info("admin_action admin=local-development-bypass action=#{event}")
    end
  end

  defp log_mutation(admin, event) do
    if MapSet.member?(@mutating_events, event) do
      require Logger
      Logger.info("admin_action admin=#{admin.email} action=#{event}")
    end
  end

  defp login_redirect(%{force_password_change: true}, _return_to), do: ~p"/admin/admins"
  defp login_redirect(_admin, return_to) when is_binary(return_to), do: return_to
  defp login_redirect(_admin, _return_to), do: ~p"/admin/dashboard"

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :admin_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp local_bypass? do
    Application.get_env(:pidro_server, :dev_routes, false)
  end
end

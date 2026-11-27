defmodule PidroServerWeb.InvitePageHTML do
  @moduledoc """
  HTML templates for the public invite landing page, and the store badges every
  link page shows (`/j/:code`, `/play/:slug`, `/app/reset-password`).
  """

  use PidroServerWeb, :html

  alias PidroServerWeb.InvitePage

  embed_templates "invite_page_html/*"

  @doc """
  The iPhone and Google Play badges, one size and shape. The iPhone one is
  Apple's App Store badge once the store is the App Store, and before that a
  black badge of our own. A link captures its deferred invite only on its own
  platform.
  """
  attr :page, :map, required: true
  attr :iphone, :map, default: %{small: "Get Pidro for", label: "Get Pidro for iPhone"}

  def store_badges(assigns) do
    assigns =
      assign(assigns,
        app_store: InvitePage.app_store?(),
        capture: Map.get(assigns.page, :deferred_capture_url),
        device: Map.get(assigns.page, :device)
      )

    ~H"""
    <div
      :if={@page.iphone_install_url || @page.play_store_url}
      class="invite-store-links"
      aria-label="Download Pidro"
    >
      <a
        :if={@page.iphone_install_url}
        href={@page.iphone_install_url}
        class={!@app_store && "invite-badge"}
        data-store="apple"
        data-deferred-capture={if @device == :ios, do: @capture}
        data-deferred-platform={if @device == :ios and @capture, do: "ios"}
        aria-label={if @app_store, do: "Download on the App Store", else: @iphone.label}
      >
        <img
          :if={@app_store}
          src={static_url(PidroServerWeb.Endpoint, ~p"/images/invite/app-store.png")}
          width="153"
          height="50"
          alt="Download on the App Store"
        />
        <svg :if={!@app_store} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
          <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701" />
        </svg>
        <span :if={!@app_store}>{@iphone.small}<strong>iPhone</strong></span>
      </a>
      <a
        :if={@page.play_store_url}
        href={@page.play_store_url}
        data-store="google"
        data-deferred-capture={if @device == :android, do: @capture}
        data-deferred-platform={if @device == :android and @capture, do: "android"}
        aria-label="Get Pidro on Google Play"
      >
        <img
          src={static_url(PidroServerWeb.Endpoint, ~p"/images/invite/google-play.png")}
          width="168"
          height="50"
          alt="Get it on Google Play"
        />
      </a>
    </div>
    """
  end
end

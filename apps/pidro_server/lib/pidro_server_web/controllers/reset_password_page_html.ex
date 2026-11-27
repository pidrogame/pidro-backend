defmodule PidroServerWeb.ResetPasswordPageHTML do
  @moduledoc """
  The browser reset page, in English and Swedish. The words are the app's own
  (`auth.choose_password`, `auth.reset_invalid`, `auth.check_inbox` ...), so
  the page and the app's reset screen say the same thing.
  """

  use PidroServerWeb, :html

  import PidroServerWeb.InvitePageHTML, only: [store_badges: 1]

  embed_templates "reset_password_page_html/*"

  @copy %{
    en: %{
      lang: "en",
      title: "Choose a new password · Pidro",
      description: "Choose a new password for your Pidro account.",
      heading: "Choose a new password",
      label: "New password",
      rule: "8 characters or more",
      too_short: "Use 8 characters or more.",
      show: "Show",
      hide: "Hide",
      submit: "Set new password",
      done_heading: "Your password is changed",
      done_body: "Open Pidro and sign in.",
      store_label: "No Pidro on this device? Get the app, it's free.",
      iphone: %{small: "Get Pidro for", label: "Get Pidro for iPhone"},
      open: "Open Pidro",
      invalid: "This reset link is missing or no longer valid.",
      identifier: "Player name or email",
      new_link: "Send a new link",
      sent_heading: "Check your email",
      sent: "If that matches a Pidro account, a link to choose a new password is on its way.",
      lifetime: "The link works for one hour."
    },
    sv: %{
      lang: "sv",
      title: "Välj ett nytt lösenord · Pidro",
      description: "Välj ett nytt lösenord för ditt Pidro-konto.",
      heading: "Välj ett nytt lösenord",
      label: "Nytt lösenord",
      rule: "Minst 8 tecken",
      too_short: "Använd minst 8 tecken.",
      show: "Visa",
      hide: "Dölj",
      submit: "Spara nytt lösenord",
      done_heading: "Ditt lösenord är ändrat",
      done_body: "Öppna Pidro och logga in.",
      store_label: "Inget Pidro på den här enheten? Hämta appen, den är gratis.",
      iphone: %{small: "Hämta Pidro för", label: "Hämta Pidro för iPhone"},
      open: "Öppna Pidro",
      invalid: "Återställningslänken saknas eller är inte längre giltig.",
      identifier: "Spelarnamn eller e-post",
      new_link: "Hämta en ny länk",
      sent_heading: "Kolla din e-post",
      sent:
        "Om uppgifterna matchar ett Pidro-konto är en länk för att välja ett nytt lösenord på väg.",
      lifetime: "Länken fungerar i en timme."
    }
  }

  @doc "The page's words in `language`, `:en` or `:sv`."
  @spec copy(:en | :sv) :: map()
  def copy(language), do: Map.fetch!(@copy, language)
end

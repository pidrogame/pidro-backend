defmodule PidroServerWeb.ResetPasswordPageHTML do
  @moduledoc """
  The browser reset page, in English and Swedish. The words are the app's own
  (`auth.choose_password`, `auth.set_password`, `auth.sign_in_forgot` ...), so
  the page and the app's reset screen say the same thing.
  """

  use PidroServerWeb, :html

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
      iphone: "Get Pidro for iPhone",
      iphone_beta: "Get Pidro Beta for iPhone",
      invalid_heading: "This reset link is no longer valid",
      invalid_body:
        "A link works once, for one hour. For a new one, open Pidro, tap Sign in, then “Forgot your password or name?”."
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
      iphone: "Hämta Pidro för iPhone",
      iphone_beta: "Hämta Pidro Beta för iPhone",
      invalid_heading: "Länken är inte längre giltig",
      invalid_body:
        "En länk fungerar en gång, i en timme. Öppna Pidro, tryck på Logga in och sedan ”Glömt lösenord eller namn?” för att få en ny."
    }
  }

  @doc "The page's words in `language`, `:en` or `:sv`."
  @spec copy(:en | :sv) :: map()
  def copy(language), do: Map.fetch!(@copy, language)
end

defmodule PidroServer.Mailer do
  use Swoosh.Mailer, otp_app: :pidro_server

  require Logger

  @doc """
  Delivers `email` like `deliver/1`, but an adapter that raises or exits
  returns `{:error, reason}` too, and every failure is logged under `label`.

  The log never holds the email: an adapter that exits inside a
  `GenServer.call`, like `Swoosh.Adapters.Local` without its storage, carries
  the whole message in its exit reason, reset links included.
  """
  def deliver_logged(email, label) do
    case deliver(email) do
      {:ok, _metadata} = sent -> sent
      {:error, reason} -> failed(label, reason)
    end
  catch
    kind, reason -> failed(label, {kind, summary(reason)})
  end

  @doc """
  Whether the SMTP encoder can write `address` into a mail. It raises or exits
  on any it cannot, such as one with `,` `;` `"` `<` or `(` before the `@` or a
  domain IDNA refuses, so this asks it rather than copying its rules.

  `Swoosh.Adapters.SMTP.Helpers.body/2` is internal to Swoosh, but it is what
  `Swoosh.Adapters.SMTP.deliver/2` sends. Should a Swoosh upgrade change it,
  every address turns unsendable and the user tests for ordinary addresses fail.
  """
  def sendable?(address) when is_binary(address) do
    mail = Swoosh.Email.new(to: address, from: "check@pidro.online", subject: "", text_body: "")
    Swoosh.Adapters.SMTP.Helpers.body(mail, [])
    true
  catch
    _kind, _reason -> false
  end

  defp failed(label, reason) do
    Logger.error("#{label} email delivery failed: #{inspect(summary(reason))}")
    {:error, reason}
  end

  @doc "A delivery failure reduced to what is safe to log or keep: never the mail or its address."
  def summary(exception) when is_exception(exception), do: exception.__struct__

  def summary({kind, reason}) when kind in [:error, :exit, :throw],
    do: {kind, summary(reason)}

  def summary({reason, {_module, _function, _args}}), do: summary(reason)
  def summary(reason) when is_atom(reason), do: reason
  def summary(_reason), do: :unknown
end

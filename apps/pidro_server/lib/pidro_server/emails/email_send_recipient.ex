defmodule PidroServer.Emails.EmailSendRecipient do
  @moduledoc """
  One player's place in an `EmailSend`. The address is never copied here.

  A row is `claimed` just before its mail goes to the mailer and settled to
  `sent` or `failed` after, so a row still `claimed` once the send stopped is
  unconfirmed and never sent again. `skipped` is a player who turned update
  emails off, or lost a sendable address, after the send started.
  """

  use Ecto.Schema

  @foreign_key_type :binary_id

  schema "email_send_recipients" do
    field :send_id, :binary_id
    belongs_to :user, PidroServer.Accounts.User
    field :state, Ecto.Enum, values: [:pending, :claimed, :sent, :failed, :skipped]

    timestamps(type: :utc_datetime_usec)
  end
end

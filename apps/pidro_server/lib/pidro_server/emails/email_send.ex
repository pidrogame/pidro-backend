defmodule PidroServer.Emails.EmailSend do
  @moduledoc """
  One mailing of a campaign template to every recipient it had when it started.

  `template` is a snapshot of what was sent, so editing or deleting the
  template afterwards does not change the record. `state` is `running` while a
  delivery process owns it; a `running` send with no live process stopped in a
  crash or a deploy.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "email_sends" do
    belongs_to :email_template, PidroServer.Emails.EmailTemplate, foreign_key: :template_id
    field :template, :map
    field :started_by, :string
    field :state, Ecto.Enum, values: [:running, :paused, :finished]
    field :paused_reason, :string
    field :finished_at, :utc_datetime_usec
    field :counts, :map, virtual: true

    has_many :recipients, PidroServer.Emails.EmailSendRecipient, foreign_key: :send_id

    timestamps(type: :utc_datetime_usec)
  end
end

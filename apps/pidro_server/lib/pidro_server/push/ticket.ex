defmodule PidroServer.Push.Ticket do
  @moduledoc "A message Expo accepted for one token, and the receipt it later had."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "push_tickets" do
    field :token_id, :id
    field :ticket_id, :string
    field :title, :string
    field :sent_at, :utc_datetime_usec
    field :receipt_status, :string
    field :receipt_error, :string
    field :checked_at, :utc_datetime_usec
  end
end

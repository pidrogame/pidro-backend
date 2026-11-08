defmodule PidroServer.Push.Token do
  @moduledoc """
  One phone's Expo push token. `last_used_at` is when the app last registered
  it; a disabled token gets no pushes until the app registers it again.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @format ~r/\AExp(?:onent|o)PushToken\[[^\[\]\s]+\]\z/

  @type t :: %__MODULE__{}

  schema "push_tokens" do
    field :user_id, :binary_id
    field :token, :string
    field :platform, :string
    field :install_id, :string
    field :app_version, :string
    field :app_build, :string
    field :last_used_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :disabled_reason, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token, :platform, :install_id, :app_version])
    # A build that is not digits is dropped, not refused: a refused phone gets no push.
    |> put_change(:app_build, build(attrs["app_build"]))
    |> validate_required([:token, :platform])
    |> validate_format(:token, @format, message: "is not an Expo push token")
    |> validate_length(:token, max: 255)
    |> validate_inclusion(:platform, ~w(ios android))
    |> validate_length(:install_id, max: 64)
    |> validate_length(:app_version, max: 32)
  end

  defp build(build) when is_binary(build), do: if(build =~ ~r/\A\d{1,10}\z/, do: build)
  defp build(_build), do: nil
end

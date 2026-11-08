defmodule PidroServer.Push do
  @moduledoc """
  Push notifications through Expo (PID-392): the phones each player's app
  registers, one message to all of a player's phones, and the receipts Expo
  has for those messages a quarter of an hour later. A phone Expo calls
  `DeviceNotRegistered` gets no pushes until the app registers it again.
  """

  import Kernel, except: [send: 2]
  import Ecto.Query
  require Logger

  alias PidroServer.Accounts.User
  alias PidroServer.Push.{Expo, Ticket, Token}
  alias PidroServer.Repo

  @type message :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          optional(:data) => map()
        }

  @doc "Registers a phone for `user`, taking it over from whoever had it, and turns it back on."
  @spec register(User.t(), map()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def register(%User{id: user_id}, attrs) do
    %Token{user_id: user_id, last_used_at: DateTime.utc_now()}
    |> Token.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :user_id,
           :platform,
           :install_id,
           :app_version,
           :app_build,
           :last_used_at,
           :disabled_at,
           :disabled_reason,
           :updated_at
         ]},
      conflict_target: :token,
      returning: true
    )
  end

  @doc "Forgets the caller's own token; anyone else's stays."
  @spec unregister(User.t(), String.t()) :: :ok
  def unregister(%User{id: user_id}, token) do
    Repo.delete_all(from t in Token, where: t.user_id == ^user_id and t.token == ^token)
    :ok
  end

  @doc "The phones a push to this player goes to."
  @spec tokens_for(Ecto.UUID.t()) :: [Token.t()]
  def tokens_for(user_id) do
    Repo.all(
      from t in Token,
        where: t.user_id == ^user_id and is_nil(t.disabled_at),
        order_by: [t.inserted_at, t.id]
    )
  end

  @doc "Every phone of a player, disabled ones too, newest first."
  @spec devices(Ecto.UUID.t()) :: [Token.t()]
  def devices(user_id) do
    Repo.all(
      from t in Token, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  @doc "A player's latest tickets, newest first."
  @spec latest_tickets(Ecto.UUID.t(), pos_integer()) :: [Ticket.t()]
  def latest_tickets(user_id, limit \\ 10) do
    Repo.all(
      from k in Ticket,
        join: t in Token,
        on: t.id == k.token_id,
        where: t.user_id == ^user_id,
        order_by: [desc: k.sent_at, desc: k.id],
        limit: ^limit
    )
  end

  @doc """
  Sends one message to each of the player's phones, 100 to a request. Keeps a
  ticket for each one Expo accepted. A network or HTTP failure stops the send
  and is returned, never raised.
  """
  @spec send(Ecto.UUID.t(), message()) ::
          {:ok, %{sent: non_neg_integer(), failed: non_neg_integer()}} | {:error, term()}
  def send(user_id, %{title: title, body: body} = message) do
    user_id
    |> tokens_for()
    |> Enum.chunk_every(100)
    |> Enum.reduce_while({:ok, %{sent: 0, failed: 0}}, fn batch, {:ok, counts} ->
      messages =
        Enum.map(batch, fn token ->
          %{
            to: token.token,
            title: title,
            body: body,
            data: Map.get(message, :data, %{}),
            sound: "default",
            channelId: "default"
          }
        end)

      case Expo.send_messages(messages) do
        {:ok, tickets} ->
          {:cont,
           {:ok, batch |> Enum.zip(tickets) |> Enum.reduce(counts, &record(&1, &2, title))}}

        {:error, reason} ->
          Logger.warning("Push to user #{user_id} failed: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  end

  defp record({token, %{"status" => "ok", "id" => id}}, counts, title) do
    Repo.insert!(%Ticket{
      token_id: token.id,
      ticket_id: id,
      title: title,
      sent_at: DateTime.utc_now()
    })

    %{counts | sent: counts.sent + 1}
  end

  defp record({token, ticket}, counts, _title) do
    reason = reason(ticket)
    # Only the code: Expo's message quotes the token itself.
    Logger.warning("Push to token #{token.id} failed: #{reason}")
    if reason == "DeviceNotRegistered", do: disable(token.id, reason, DateTime.utc_now())
    %{counts | failed: counts.failed + 1}
  end

  @doc """
  Reads the receipts of tickets sent at least 15 minutes ago, as Expo asks,
  stores each one and disables phones that are no longer registered. A ticket
  without a receipt yet waits for the next run.
  """
  @spec check_receipts() :: {:ok, %{checked: non_neg_integer()}} | {:error, term()}
  def check_receipts do
    due = DateTime.add(DateTime.utc_now(), -15, :minute)

    from(k in Ticket, where: is_nil(k.checked_at) and k.sent_at <= ^due, order_by: k.sent_at)
    |> Repo.all()
    |> Enum.chunk_every(1000)
    |> Enum.reduce_while({:ok, %{checked: 0}}, fn batch, {:ok, %{checked: checked}} ->
      case Expo.get_receipts(Enum.map(batch, & &1.ticket_id)) do
        {:ok, receipts} ->
          stored = Enum.count(batch, &store_receipt(&1, receipts[&1.ticket_id]))
          {:cont, {:ok, %{checked: checked + stored}}}

        {:error, reason} ->
          Logger.warning("Push receipts failed: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  end

  # Expo keeps a receipt for a day; past that there is nothing left to wait for.
  defp store_receipt(ticket, nil),
    do:
      DateTime.diff(DateTime.utc_now(), ticket.sent_at, :hour) >= 24 and
        checked(ticket, "expired", nil)

  defp store_receipt(ticket, %{"status" => "ok"}), do: checked(ticket, "ok", nil)

  defp store_receipt(ticket, receipt) do
    reason = reason(receipt)
    Logger.warning("Push ticket #{ticket.ticket_id} failed: #{reason}")
    if reason == "DeviceNotRegistered", do: disable(ticket.token_id, reason, ticket.sent_at)
    checked(ticket, "error", reason)
  end

  defp checked(ticket, status, error) do
    Repo.update_all(from(k in Ticket, where: k.id == ^ticket.id),
      set: [receipt_status: status, receipt_error: error, checked_at: DateTime.utc_now()]
    )

    true
  end

  defp reason(%{"details" => %{"error" => error}}) when is_binary(error), do: error
  defp reason(%{"message" => message}) when is_binary(message), do: message
  defp reason(_), do: "unknown"

  # A phone the app registered again after `sent` keeps its fresh token.
  defp disable(token_id, reason, sent) do
    now = DateTime.utc_now()

    Repo.update_all(from(t in Token, where: t.id == ^token_id and t.last_used_at <= ^sent),
      set: [disabled_at: now, disabled_reason: reason, updated_at: now]
    )
  end
end

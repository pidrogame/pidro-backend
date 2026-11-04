defmodule PidroServer.Games.SeatLifecycle do
  @moduledoc "Resolves account and cached bot profiles outside the shared room manager."
  alias PidroServer.Accounts.Auth
  alias PidroServer.BotCatalogue

  def with_names(snapshot) do
    user_ids =
      snapshot.seats
      |> Map.values()
      |> Enum.flat_map(fn seat -> [seat.player_id, seat.decision && seat.decision.player_id] end)
      |> Enum.filter(&match?({:ok, _}, Ecto.UUID.dump(&1)))
      |> Enum.uniq()

    users = Auth.get_users_map(user_ids)

    seats =
      Map.new(snapshot.seats, fn {position, seat} ->
        decision =
          if seat.decision do
            %{
              id: seat.decision.id,
              player_name: username(users, seat.decision.player_id)
            }
          end

        seat = Map.put(seat, :bot_profile, nil)

        resolved_seat =
          cond do
            seat.status == :permanent_bot ->
              profile = BotCatalogue.profile(seat.bot_persona)
              name = if profile, do: profile.name, else: "Bot"

              seat
              |> Map.put(:bot_profile, if(profile, do: BotCatalogue.public(profile)))
              |> Map.put(:username, name)
              |> Map.put(:display_name, name)
              |> Map.put(:avatar_url, if(profile, do: BotCatalogue.avatar_url(profile)))
              |> Map.put(:level, nil)
              |> Map.put(:prestige, nil)
              |> Map.put(:pin, nil)

            seat.player_id ->
              seat
              |> Map.put(:username, username(users, seat.player_id))
              |> Map.put(:display_name, display_name(users, seat.player_id))
              |> Map.put(:avatar_url, avatar_url(users, seat.player_id))
              |> Map.put(:level, user_field(users, seat.player_id, :level))
              |> Map.put(:prestige, user_field(users, seat.player_id, :prestige))
              |> Map.put(:pin, user_field(users, seat.player_id, :pin))

            true ->
              seat
              |> Map.put(:display_name, seat.username)
              |> Map.put(:avatar_url, nil)
              |> Map.put(:level, nil)
              |> Map.put(:prestige, nil)
              |> Map.put(:pin, nil)
          end

        {position, %{resolved_seat | decision: decision}}
      end)

    %{snapshot | seats: seats}
  end

  defp username(users, user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.username
    end
  end

  defp display_name(users, user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.display_name
    end
  end

  defp avatar_url(users, user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.avatar_url
    end
  end

  defp user_field(users, user_id, field) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> Map.fetch!(user, field)
    end
  end
end

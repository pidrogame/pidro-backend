defmodule PidroServerWeb.ErrorContract do
  @moduledoc """
  Additive, locale-independent error metadata at the HTTP/channel boundary.

  Codes come from known domain reasons or existing stable protocol codes, never
  English text. Only explicitly selected numeric parameters may cross this
  boundary; exception text, credentials and arbitrary tuple contents may not.
  The public vocabulary is documented in docs/contracts/localization-errors.json.
  """

  @simple_codes ~w(
    request_failed action_failed validation_failed field_invalid field_required
    field_taken field_format classic_name_reserved unauthorized forbidden not_found
    invalid_credentials mail_unavailable provider_unavailable account_inactive
    classic_account_not_found classic_email_missing classic_code_invalid
    claim_binding_required already_claimed user_already_claimed provider_already_linked
    claim_ticket_expired invalid_claim_ticket claim_ticket_binding_mismatch claim_state_changed
    invalid_or_expired_password_reset_token account_required not_a_guest email_taken
    username_taken creation_conflict age_already_set age_not_eligible room_not_found
    room_full already_in_room already_in_this_room not_in_room
    player_not_in_room seat_not_controlled invalid_locked
    room_not_available_for_spectators spectators_full already_spectating not_spectating
    profile_unavailable seat_requires_password seat_taken team_full invalid_position room_not_available
    not_owner room_not_playing seat_not_bot_substitute seat_not_vacant already_seated
    no_vacant_seat invitation_gone no_seat_for_you table_full room_not_waiting invite_limit table_started table_closed
    invite_expired invite_revoked invite_moved table_locked kicked seat_not_kickable
    room_code_exhausted invalid_room_params seat_permanently_filled grace_period_expired
    player_not_disconnected spectator_action_forbidden invalid_readiness stale_readiness
    stale_identity table_not_full room_not_finished stale_decision game_unavailable
    invalid_phase not_your_turn already_played_for_you invalid_action invalid_bid_amount bid_too_low already_bid
    already_passed already_acted dealer_must_bid invalid_suit trump_already_declared
    trump_not_declared invalid_card card_not_in_hand cards_not_in_hand must_follow_suit
    cannot_play_non_trump cannot_discard_trump can_only_kill_trump cannot_kill_point_cards
    no_dealer not_dealer_turn invalid_card_count player_eliminated game_already_complete
    invalid_team cannot_friend_self cannot_block_self user_not_found query_too_short avatar_too_large
    avatar_dimensions avatar_unsupported_type avatar_result_too_large avatar_busy avatar_invalid
  )a

  @legacy_codes Map.new(@simple_codes, &{String.upcase(Atom.to_string(&1)), &1})
  @length_codes [:field_too_short, :field_too_long, :field_wrong_length]

  @doc "Adds localization metadata without changing any legacy payload fields."
  @spec add(map(), term(), :request_failed | :action_failed) :: map()
  def add(payload, reason, fallback \\ :request_failed) do
    Map.merge(payload, descriptor(reason, fallback))
  end

  @doc "Adds metadata to a legacy REST error with an allowlisted stable code."
  @spec rest(map()) :: map()
  def rest(%{error: "SEAT_REQUIRES_GAMES", min_games: min, games_played: played} = payload),
    do: add(payload, {:seat_requires_games, min, played})

  def rest(%{errors: [%{code: code}]} = payload),
    do: add(payload, Map.get(@legacy_codes, code))

  def rest(%{error: code} = payload), do: add(payload, Map.get(@legacy_codes, code))
  def rest(payload), do: add(payload, :request_failed)

  @doc "Adds parallel field errors, preserving the old validation envelope verbatim."
  @spec validation(map(), Ecto.Changeset.t() | [map()]) :: map()
  def validation(payload, %Ecto.Changeset{} = changeset) do
    fields =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {_message, opts} ->
        descriptor(validation_reason(opts), :field_invalid)
      end)
      |> flatten_fields("")

    payload |> add(:validation_failed) |> Map.put(:field_errors, fields)
  end

  def validation(payload, errors) when is_list(errors) do
    fields = Enum.map(errors, &field(&1.field, :field_invalid))
    payload |> add(:validation_failed) |> Map.put(:field_errors, fields)
  end

  @doc "Builds a field error using a stable field identity and a known reason."
  @spec field(atom() | String.t(), term()) :: map()
  def field(name, reason),
    do: Map.put(descriptor(reason, :field_invalid), :field, to_string(name))

  defp descriptor({:seat_requires_games, min, played}, _fallback)
       when is_integer(min) and is_integer(played),
       do: %{
         error_code: "seat_requires_games",
         error_params: %{min_games: min, games_played: played}
       }

  defp descriptor({:rate_limited, seconds}, _fallback) when is_integer(seconds),
    do: %{error_code: "rate_limited", error_params: %{retry_after: seconds}}

  defp descriptor({code, count}, _fallback) when code in @length_codes and is_integer(count),
    do: %{error_code: Atom.to_string(code), error_params: %{count: count}}

  # Engine tuples also contain cards, actions and sometimes English diagnostics.
  # Only the allowlisted tag is public metadata, never those tuple contents.
  defp descriptor(reason, fallback) when is_tuple(reason) and tuple_size(reason) > 0,
    do: descriptor(elem(reason, 0), fallback)

  defp descriptor(reason, _fallback) when reason in @simple_codes,
    do: %{error_code: Atom.to_string(reason), error_params: %{}}

  defp descriptor(_reason, fallback),
    do: %{error_code: Atom.to_string(fallback), error_params: %{}}

  defp validation_reason(opts) do
    case {opts[:code], opts[:constraint], opts[:validation], opts[:kind]} do
      {:classic_name_reserved, _, _, _} -> :classic_name_reserved
      {_, :unique, _, _} -> :field_taken
      {_, _, :unsafe_unique, _} -> :field_taken
      {_, _, :required, _} -> :field_required
      {_, _, :format, _} -> :field_format
      {_, _, :length, :min} -> {:field_too_short, opts[:count]}
      {_, _, :length, :max} -> {:field_too_long, opts[:count]}
      {_, _, :length, :is} -> {:field_wrong_length, opts[:count]}
      _ -> :field_invalid
    end
  end

  defp flatten_fields(errors, prefix) do
    Enum.flat_map(errors, fn {name, entries} ->
      path = prefix <> to_string(name)

      Enum.flat_map(List.wrap(entries), fn
        %{error_code: _} = error -> [Map.put(error, :field, path)]
        nested when is_map(nested) -> flatten_fields(nested, path <> ".")
      end)
    end)
  end
end

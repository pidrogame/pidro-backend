defmodule PidroServer.Games.PacingSettings do
  @moduledoc """
  Runtime helpers for the editable pacing values exposed in the dev panel.
  """

  alias PidroServer.Games.Lifecycle

  @field_specs [
    %{
      key: :bot_delay_ms,
      label: "Bot Base Delay",
      description: "Base delay before any bot action.",
      min: 0,
      max: 10_000,
      step: 50
    },
    %{
      key: :own_bot_delay_ms,
      label: "Own Pace Bot Delay",
      description: "Base bot delay at an own-pace table, with the same random variance.",
      min: 0,
      max: 10_000,
      step: 50
    },
    %{
      key: :bot_delay_variance_ms,
      label: "Bot Delay Variance",
      description: "Random +/- variance applied to the base bot delay.",
      min: 0,
      max: 5_000,
      step: 50
    },
    %{
      key: :bot_min_delay_ms,
      label: "Bot Minimum Delay",
      description: "Floor applied after variance so bots never act instantly.",
      min: 0,
      max: 5_000,
      step: 50
    },
    %{
      key: :trick_transition_delay_ms,
      label: "Trick Transition Delay",
      description: "Pause after a trick completes before the next one begins.",
      min: 0,
      max: 10_000,
      step: 50
    },
    %{
      key: :own_trick_transition_delay_ms,
      label: "Own Pace Trick Delay",
      description: "Pause after each completed trick at an own-pace table.",
      min: 0,
      max: 10_000,
      step: 50
    },
    %{
      key: :deal_transition_delay_ms,
      label: "Deal Pause",
      description: "Hold bots while clients deal each hand's nine cards.",
      min: 0,
      max: 20_000,
      step: 250
    },
    %{
      key: :second_deal_transition_delay_ms,
      label: "Second Deal Pause",
      description: "Hold play while clients show the discards and the refill.",
      min: 0,
      max: 20_000,
      step: 250
    },
    %{
      key: :hand_transition_delay_ms,
      label: "Hand Transition Delay",
      description: "Pause between hands so clients can show scoring.",
      min: 0,
      max: 15_000,
      step: 50
    },
    %{
      key: :bots_offer_delay_ms,
      label: "Bots Offer Delay",
      description:
        "How long after the last change a waiting table with an open seat offers its host bots. Blank or 0 turns the offer off.",
      min: 0,
      max: 600_000,
      step: 1_000,
      blank: 0
    }
  ]

  @keys Enum.map(@field_specs, & &1.key)

  @type values_t :: %{optional(atom()) => non_neg_integer()}
  @type form_t :: %{optional(String.t()) => String.t()}
  @type errors_t :: %{optional(String.t()) => String.t()}

  @spec field_specs() :: [map()]
  def field_specs, do: @field_specs

  @spec current_values() :: values_t()
  def current_values do
    Map.new(@keys, fn key -> {key, Lifecycle.config(key)} end)
  end

  @spec current_form() :: form_t()
  def current_form do
    current_values() |> stringify_values()
  end

  @spec default_values() :: values_t()
  def default_values do
    Lifecycle.defaults() |> Map.take(@keys)
  end

  @spec default_form() :: form_t()
  def default_form do
    default_values() |> stringify_values()
  end

  @spec normalize_form(map() | nil) :: form_t()
  def normalize_form(nil), do: current_form()

  def normalize_form(form) when is_map(form) do
    base = current_form()

    Enum.reduce(@field_specs, base, fn %{key: key}, acc ->
      string_key = Atom.to_string(key)

      value =
        cond do
          Map.has_key?(form, string_key) -> Map.get(form, string_key)
          Map.has_key?(form, key) -> Map.get(form, key)
          true -> Map.get(acc, string_key)
        end

      Map.put(acc, string_key, stringify(value))
    end)
  end

  @spec validate(map() | nil) :: {:ok, values_t()} | {:error, form_t(), errors_t()}
  def validate(form) do
    normalized = normalize_form(form)

    {values, errors} =
      Enum.reduce(@field_specs, {%{}, %{}}, fn spec, {values_acc, errors_acc} ->
        string_key = Atom.to_string(spec.key)

        case parse_field(Map.get(normalized, string_key), spec) do
          {:ok, value} ->
            {Map.put(values_acc, spec.key, value), errors_acc}

          {:error, message} ->
            {values_acc, Map.put(errors_acc, string_key, message)}
        end
      end)

    if map_size(errors) == 0 do
      {:ok, values}
    else
      {:error, normalized, errors}
    end
  end

  @spec save(values_t()) :: values_t()
  def save(values) when is_map(values) do
    existing = Application.get_env(:pidro_server, Lifecycle, [])
    merged = Keyword.merge(existing, Map.to_list(values))
    Application.put_env(:pidro_server, Lifecycle, merged)
    current_values()
  end

  @spec reset() :: values_t()
  def reset do
    save(default_values())
  end

  @spec preview(map() | nil) :: %{
          bot_delay_min_ms: non_neg_integer(),
          bot_delay_max_ms: non_neg_integer()
        }
  def preview(form) do
    values = preview_values(form)
    base = Map.fetch!(values, :bot_delay_ms)
    variance = Map.fetch!(values, :bot_delay_variance_ms)
    min_delay = Map.fetch!(values, :bot_min_delay_ms)

    %{
      bot_delay_min_ms: max(base - variance, min_delay),
      bot_delay_max_ms: max(base + variance, min_delay)
    }
  end

  defp preview_values(form) do
    current = current_values()
    normalized = normalize_form(form)

    Enum.reduce(@field_specs, current, fn spec, acc ->
      string_key = Atom.to_string(spec.key)

      case Integer.parse(Map.get(normalized, string_key, "")) do
        {value, ""} ->
          Map.put(acc, spec.key, value)

        _ ->
          acc
      end
    end)
  end

  defp parse_field(value, %{blank: blank}) when value in [nil, ""], do: {:ok, blank}
  defp parse_field(nil, spec), do: {:error, range_message(spec)}
  defp parse_field("", spec), do: {:error, range_message(spec)}

  defp parse_field(value, spec) do
    case Integer.parse(stringify(value)) do
      {parsed, ""} when parsed >= spec.min and parsed <= spec.max ->
        {:ok, parsed}

      _ ->
        {:error, range_message(spec)}
    end
  end

  defp range_message(spec) do
    "Enter a value between #{spec.min}ms and #{spec.max}ms"
  end

  defp stringify_values(values) do
    Map.new(values, fn {key, value} -> {Atom.to_string(key), stringify(value)} end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(nil), do: ""
  defp stringify(value), do: to_string(value)
end

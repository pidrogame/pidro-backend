defmodule PidroServerWeb.CardComponents do
  @moduledoc """
  Visual card table components for Pidro game development UI.

  This module provides Phoenix LiveView components for rendering:
  - Individual playing cards (.card)
  - Player hands (.hand)
  - Trick area (.trick_area)
  - Complete card table (.card_table)
  - Phase-specific displays (.bidding_panel, .trump_selection_panel)

  These components are designed for the development UI and provide
  visual representations of game state for testing and debugging.

  ## Usage

  In your LiveView template:

      <.card_table
        game_state={@game_state}
        selected_position={@selected_position}
        god_mode={@selected_position == :all}
        legal_actions={@legal_actions}
      />
  """

  use Phoenix.Component
  import PidroServerWeb.CardHelpers

  @doc "Read-only admin table. Accepts a game snapshot and enriched lifecycle seats, never a process."
  attr :game_state, :map, default: nil
  attr :seats, :map, default: %{}
  attr :perspective, :atom, default: :all

  def watch_table(assigns) do
    assigns = assign(assigns, :state, assigns.game_state || %{})

    ~H"""
    <section id="watch-table" class="watch-table" aria-label="Private admin Pidro table">
      <header class="watch-scoreboard">
        <div class="watch-team-ns">
          North / South <strong>{get_score(@state, :north_south)}</strong>
        </div>
        <div class="watch-team-ew">East / West <strong>{get_score(@state, :east_west)}</strong></div>
      </header>
      <div class="watch-felt">
        <article
          :for={position <- [:north, :west, :east, :south]}
          id={"watch-seat-#{position}"}
          class={[
            "watch-seat",
            "watch-seat-#{position}",
            get_current_turn(@state) == position && "watch-turn"
          ]}
          aria-label={"#{position_label(position)} seat#{if get_current_turn(@state) == position, do: ", current turn", else: ""}"}
        >
          <.seat_identity seat={@seats[position]} position={position} />
          <div class="watch-seat-state">
            <strong :if={get_current_turn(@state) == position}>● TURN</strong>
            <span :if={get_dealer(@state) == position} class="watch-dealer">D · Dealer</span>
            <span :if={player_is_cold?(@state, position)}>Cold</span>
          </div>
          <div
            class="watch-hand"
            style={"--card-count: #{max(length(get_hand(@state, position)), 1)}"}
          >
            <.mobile_card
              :for={card <- sort_hand(get_hand(@state, position), get_trump_suit(@state))}
              card={if @perspective in [:all, position], do: card, else: nil}
            />
          </div>
          <span class="watch-card-count">{length(get_hand(@state, position))} cards</span>
        </article>
        <div class="watch-center">
          <p class="watch-phase">
            {Map.get(@state, :phase, :waiting) |> to_string() |> String.replace("_", " ")}
          </p>
          <p>Trump <strong>{format_trump(get_trump_suit(@state))}</strong></p>
          <p :if={get_current_bid(@state)}>
            Bid <strong>{get_current_bid(@state)}</strong> · {get_current_bidder(@state)}
          </p>
          <div class="watch-trick" aria-label="Current trick">
            <div
              :for={play <- get_current_trick(@state)}
              class={"watch-play watch-play-#{play.position}"}
            >
              <.mobile_card card={play.card} />
              <span>{position_abbrev(play.position)}</span>
            </div>
          </div>
          <p :if={Map.get(@state, :winner)} class="watch-winner">
            Winner: {Map.get(@state, :winner)}
          </p>
        </div>
      </div>
      <footer class="watch-table-footer">
        <span>Hand {get_hand_number(@state)} · Trick {get_trick_number(@state)}</span>
        <span>Private · {if @perspective == :all, do: "all hands", else: "#{@perspective} hand only"}</span>
      </footer>
    </section>
    """
  end

  attr :card, :any, required: true

  defp mobile_card(assigns) do
    ~H"""
    <img
      class="watch-card"
      src={mobile_card_url(@card)}
      alt={if @card, do: format_card(@card), else: "Face-down card"}
      draggable="false"
    />
    """
  end

  defp mobile_card_url(nil), do: "/images/pidro/cards/cardback.png"
  defp mobile_card_url({rank, suit}), do: "/images/pidro/cards/#{suit}_#{rank}.png"

  @doc "Identity from SeatLifecycle.with_names/1; optional bot_profile is the catalogue contract."
  attr :seat, :map, default: nil
  attr :position, :atom, required: true

  def seat_identity(assigns) do
    seat = assigns.seat || %{}
    profile = Map.get(seat, :bot_profile) || %{}

    assigns =
      assigns
      |> assign(:name, seat_name(seat))
      |> assign(:avatar, Map.get(profile, :avatar_url) || Map.get(seat, :avatar_url))
      |> assign(:href, seat_link(seat))
      |> assign(:status, Map.get(seat, :status, :vacant))
      |> assign(:status_label, Map.get(seat, :status_label))

    ~H"""
    <div class={[
      "watch-identity",
      if(@position in [:north, :south], do: "watch-team-ns", else: "watch-team-ew")
    ]}>
      <span class="watch-avatar">
        <span aria-hidden="true">{if @status == :permanent_bot, do: "⚙", else: String.first(@name)}</span>
        <img :if={@avatar} src={@avatar} alt="" loading="lazy" onerror="this.hidden=true" />
      </span>
      <a :if={@href} href={@href} class="watch-name">{@name}</a>
      <strong :if={!@href} class="watch-name">{@name}</strong>
      <span class="watch-seat-label">{position_label(@position)} · {if @position in [:north, :south],
        do: "N/S",
        else: "E/W"}</span>
      <span class="watch-connection">{@status_label || seat_status(@status)}</span>
    </div>
    """
  end

  @doc "Public name without email or internal seat identifiers."
  def seat_name(nil), do: "Open seat"
  def seat_name(%{bot_profile: %{name: name}}) when is_binary(name), do: name

  def seat_name(%{status: :permanent_bot} = seat),
    do: Map.get(seat, :display_name) || Map.get(seat, :username) || "Bot"

  def seat_name(seat),
    do:
      Map.get(seat, :display_name) || Map.get(seat, :username) ||
        if(Map.get(seat, :status) == :vacant, do: "Open seat", else: "Player")

  defp seat_link(%{status: :permanent_bot}), do: "/admin/bots"

  defp seat_link(%{player_id: id}) when is_binary(id),
    do: "/admin/users/#{URI.encode_www_form(id)}"

  defp seat_link(_), do: nil

  defp seat_status(:normal), do: "Connected"
  defp seat_status(:permanent_bot), do: "Bot"
  defp seat_status(:bot_substitute), do: "Bot covering · reserved"
  defp seat_status(:reconnecting), do: "Reconnecting"
  defp seat_status(:vacant), do: "Open"
  defp seat_status(status), do: to_string(status)

  # =============================================================================
  # Card Component
  # =============================================================================

  @doc """
  Renders a single playing card.

  ## Attributes

  - `card` - Card tuple `{rank, suit}` or `nil` for face-down
  - `face_down` - Boolean, show card back instead of face
  - `playable` - Boolean, highlight as clickable
  - `trump` - Boolean, show trump indicator (star)
  - `points` - Integer, show point badge if > 0
  - `size` - Atom, :sm | :md | :lg
  - `on_click` - Boolean, enable click handler
  - `selected` - Boolean, highlight as selected

  ## Examples

      <.card card={{14, :hearts}} playable={true} trump={true} points={1} />
      <.card card={nil} face_down={true} />
  """
  attr :card, :any, required: true
  attr :face_down, :boolean, default: false
  attr :playable, :boolean, default: false
  attr :trump, :boolean, default: false
  attr :points, :integer, default: 0
  attr :size, :atom, default: :md
  attr :on_click, :boolean, default: false
  attr :selected, :boolean, default: false

  def card(assigns) do
    ~H"""
    <div
      class={card_classes(@face_down, @playable, @trump, @size, @selected)}
      phx-click={@on_click && "play_card"}
      phx-value-card={@card && encode_card(@card)}
    >
      <%= if @face_down do %>
        <div class="card-back bg-blue-800 rounded flex items-center justify-center h-full">
          <span class="text-blue-200 text-2xl">🂠</span>
        </div>
      <% else %>
        <div class="relative h-full flex flex-col justify-between p-1">
          <div class={suit_color(@card)}>
            {format_rank(elem(@card, 0))}
          </div>
          <div class={["text-center text-xl", suit_color(@card)]}>
            {suit_symbol(elem(@card, 1))}
          </div>
          <div class={["text-right", suit_color(@card)]}>
            {format_rank(elem(@card, 0))}
          </div>
          <%= if @points > 0 do %>
            <div class="absolute -top-1 -right-1 bg-yellow-400 text-black text-xs rounded-full w-4 h-4 flex items-center justify-center font-bold">
              {@points}
            </div>
          <% end %>
          <%= if @trump do %>
            <div class="absolute -bottom-1 -left-1 text-yellow-400 text-xs">★</div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp card_classes(face_down, playable, trump, size, selected) do
    base = "rounded shadow border relative transition-all duration-200"
    size_class = size_class(size)
    bg_class = if face_down, do: "bg-blue-800", else: "bg-white"

    trump_class =
      if trump and not face_down, do: "ring-2 ring-yellow-400", else: "border-gray-300"

    selected_class =
      if selected, do: "ring-4 ring-blue-500 -translate-y-4 z-10", else: ""

    playable_class =
      if playable and not selected,
        do: "cursor-pointer hover:ring-2 hover:ring-blue-500 hover:-translate-y-1",
        else: if(selected, do: "cursor-pointer", else: "")

    [base, size_class, bg_class, trump_class, selected_class, playable_class]
  end

  defp size_class(:sm), do: "w-8 h-12 text-xs"
  defp size_class(:md), do: "w-12 h-16 text-sm"
  defp size_class(:lg), do: "w-16 h-24 text-base"

  # =============================================================================
  # Hand Component
  # =============================================================================

  @doc """
  Renders a player's hand of cards.

  ## Attributes

  - `cards` - List of card tuples
  - `position` - Player position (:north | :south | :east | :west)
  - `is_current_turn` - Boolean, highlight if active player
  - `is_human` - Boolean, show human indicator
  - `show_cards` - Boolean, face-up or face-down
  - `legal_plays` - List of playable cards (for highlighting)
  - `trump_suit` - Atom, to mark trump cards
  - `is_cold` - Boolean, player has gone cold
  - `orientation` - Atom, :horizontal or :vertical layout

  ## Examples

      <.hand
        cards={[{14, :hearts}, {13, :hearts}]}
        position={:south}
        is_current_turn={true}
        is_human={true}
        show_cards={true}
        legal_plays={[{14, :hearts}]}
        trump_suit={:hearts}
      />
  """
  attr :cards, :list, required: true
  attr :position, :atom, required: true
  attr :player_name, :string, default: nil
  attr :is_current_turn, :boolean, default: false
  attr :is_human, :boolean, default: false
  attr :is_bot, :boolean, default: false
  attr :show_cards, :boolean, default: true
  attr :legal_plays, :list, default: []
  attr :trump_suit, :atom, default: nil
  attr :is_cold, :boolean, default: false
  attr :is_dealer, :boolean, default: false
  attr :selected_cards, :list, default: []
  attr :can_select, :boolean, default: false
  attr :orientation, :atom, default: :horizontal
  attr :align, :atom, default: :start

  def hand(assigns) do
    ~H"""
    <div class={hand_container_classes(@is_current_turn)}>
      <div
        class={[
          "flex items-center gap-2 mb-1 cursor-pointer hover:text-blue-300 transition-colors select-none",
          header_align_class(@align)
        ]}
        phx-click="select_position"
        phx-value-position={@position}
        title="Click to switch view to this player"
      >
        <span class="font-medium text-sm text-white">
          {position_label(@position)}
          <%= if @player_name do %>
            <span class="text-green-300 ml-1">({@player_name})</span>
          <% end %>
        </span>
        <%= if @is_dealer do %>
          <div
            class="bg-yellow-500 text-black text-xs font-bold w-5 h-5 flex items-center justify-center rounded-full border border-yellow-600 shadow-sm"
            title="Dealer"
          >
            D
          </div>
        <% end %>
        <%= if @is_human do %>
          <span class="text-blue-300 text-xs bg-blue-900/50 px-1 rounded border border-blue-500/30">
            👤 You
          </span>
        <% end %>
        <%= if @is_bot do %>
          <span class="text-purple-300 text-xs bg-purple-900/50 px-1 rounded border border-purple-500/30">
            🤖 Bot
          </span>
        <% end %>
        <%= if @is_current_turn do %>
          <span class="text-green-300 text-xs animate-pulse">← Turn</span>
        <% end %>
        <%= if @is_cold do %>
          <span class="bg-blue-200 text-blue-800 text-xs px-1 rounded">COLD</span>
        <% end %>
      </div>

      <%= if @is_cold do %>
        <div class="text-gray-300 italic text-sm">No cards remaining</div>
      <% else %>
        <div class={[cards_row_classes(@orientation), cards_align_class(@orientation, @align)]}>
          <%= for card <- sort_hand(@cards, @trump_suit) do %>
            <.card
              card={card}
              face_down={not @show_cards}
              playable={(@can_select and @is_human) or card in @legal_plays}
              selected={card in @selected_cards}
              trump={is_trump?(card, @trump_suit)}
              points={point_value(card, @trump_suit)}
              size={:md}
              on_click={(@can_select and @is_human) or card in @legal_plays}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp position_label(:north), do: "North"
  defp position_label(:south), do: "South"
  defp position_label(:east), do: "East"
  defp position_label(:west), do: "West"

  defp position_abbrev(:north), do: "N"
  defp position_abbrev(:south), do: "S"
  defp position_abbrev(:east), do: "E"
  defp position_abbrev(:west), do: "W"

  defp hand_container_classes(is_current_turn) do
    base = "p-2 rounded"
    turn = if is_current_turn, do: "bg-green-900 ring-2 ring-green-400", else: "bg-gray-800"
    [base, turn]
  end

  defp cards_row_classes(:horizontal), do: "flex gap-1 flex-wrap"
  defp cards_row_classes(:vertical), do: "flex flex-col gap-1"

  defp header_align_class(:start), do: "justify-start"
  defp header_align_class(:end), do: "justify-end"
  defp header_align_class(:center), do: "justify-center"

  defp cards_align_class(:vertical, :start), do: "items-start"
  defp cards_align_class(:vertical, :end), do: "items-end"
  defp cards_align_class(:vertical, :center), do: "items-center"
  defp cards_align_class(:horizontal, :start), do: "justify-start"
  defp cards_align_class(:horizontal, :end), do: "justify-end"
  defp cards_align_class(:horizontal, :center), do: "justify-center"

  # =============================================================================
  # Trick Area Component
  # =============================================================================

  @doc """
  Renders the central trick area showing cards played to current trick.

  ## Attributes

  - `trick` - List of maps with :position and :card keys
  - `leader` - Position that led the trick
  - `winner` - Position winning so far
  - `trump_suit` - For highlighting trump plays
  - `trick_number` - Current trick number
  - `points_in_trick` - Total points in current trick

  ## Examples

      <.trick_area
        trick={[%{position: :north, card: {14, :hearts}}]}
        leader={:north}
        winner={:north}
        trump_suit={:hearts}
        trick_number={1}
        points_in_trick={1}
      />
  """
  attr :trick, :list, default: []
  attr :leader, :atom, default: nil
  attr :winner, :atom, default: nil
  attr :trump_suit, :atom, default: nil
  attr :trick_number, :integer, default: 0
  attr :points_in_trick, :integer, default: 0

  def trick_area(assigns) do
    trick_map = Map.new(assigns.trick, fn %{position: p, card: c} -> {p, c} end)
    assigns = assign(assigns, :trick_map, trick_map)

    ~H"""
    <div class="bg-green-700 rounded-lg p-4 min-h-[200px]">
      <div class="text-center text-sm text-gray-200 mb-2">
        Trick #{@trick_number}
        <%= if @points_in_trick > 0 do %>
          <span class="text-yellow-300 font-medium">({@points_in_trick} pts)</span>
        <% end %>
      </div>
      <%!-- 2x2 Grid for trick cards --%>
      <div class="grid grid-cols-3 grid-rows-3 gap-2 place-items-center max-w-[200px] mx-auto">
        <%!-- Row 1: North --%>
        <div class="col-start-2">
          <.trick_slot
            position={:north}
            card={@trick_map[:north]}
            is_leader={@leader == :north}
            is_winner={@winner == :north}
            trump_suit={@trump_suit}
          />
        </div>
        <%!-- Row 2: West, Center, East --%>
        <div class="col-start-1 row-start-2">
          <.trick_slot
            position={:west}
            card={@trick_map[:west]}
            is_leader={@leader == :west}
            is_winner={@winner == :west}
            trump_suit={@trump_suit}
          />
        </div>
        <div class="col-start-2 row-start-2">
          <%!-- Empty center or table decoration --%>
        </div>
        <div class="col-start-3 row-start-2">
          <.trick_slot
            position={:east}
            card={@trick_map[:east]}
            is_leader={@leader == :east}
            is_winner={@winner == :east}
            trump_suit={@trump_suit}
          />
        </div>
        <%!-- Row 3: South --%>
        <div class="col-start-2 row-start-3">
          <.trick_slot
            position={:south}
            card={@trick_map[:south]}
            is_leader={@leader == :south}
            is_winner={@winner == :south}
            trump_suit={@trump_suit}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :position, :atom, required: true
  attr :card, :any, default: nil
  attr :is_leader, :boolean, default: false
  attr :is_winner, :boolean, default: false
  attr :trump_suit, :atom, default: nil

  defp trick_slot(assigns) do
    ~H"""
    <div class="relative">
      <%= if @is_leader do %>
        <div class="absolute -top-4 left-1/2 -translate-x-1/2 text-xs text-gray-300">Led</div>
      <% end %>

      <div class={[
        "w-14 h-20 rounded border-2 flex items-center justify-center",
        @is_winner && "ring-2 ring-green-400",
        (@card && "border-solid border-gray-400 bg-white") ||
          "border-dashed border-gray-400 bg-gray-700"
      ]}>
        <%= if @card do %>
          <.card
            card={@card}
            trump={is_trump?(@card, @trump_suit)}
            points={point_value(@card, @trump_suit)}
            size={:md}
          />
        <% else %>
          <span class="text-gray-400 text-xs">
            {String.first(to_string(@position)) |> String.upcase()}
          </span>
        <% end %>
      </div>

      <%= if @is_winner and @card do %>
        <div class="absolute -bottom-4 left-1/2 -translate-x-1/2 text-xs text-green-300 font-medium">
          Winner
        </div>
      <% end %>
    </div>
    """
  end

  # =============================================================================
  # Card Table Component
  # =============================================================================

  @doc """
  Renders the complete card table with all hands and trick area.

  ## Attributes

  - `game_state` - Full game state map
  - `selected_position` - Which position human is playing
  - `god_mode` - Boolean, show all hands
  - `legal_actions` - List of legal actions for highlighting

  ## Examples

      <.card_table
        game_state={@game_state}
        selected_position={:south}
        god_mode={false}
        legal_actions={@legal_actions}
      />
  """
  attr :game_state, :map, default: nil
  attr :selected_position, :atom, default: :south
  attr :god_mode, :boolean, default: false
  attr :legal_actions, :list, default: []
  attr :bot_configs, :map, default: %{}
  attr :selected_hand_cards, :list, default: []
  attr :room, :map, default: nil
  attr :users, :list, default: []
  attr :show_seat_selectors, :boolean, default: false

  def card_table(assigns) do
    waiting = is_nil(assigns.game_state)
    assigns = assign(assigns, :waiting, waiting)
    # Extract playable cards from legal actions
    legal_plays = extract_legal_plays(assigns.legal_actions)

    # Check if hand selection is active (dealer second deal)
    can_select_hand =
      Enum.any?(assigns.legal_actions, fn
        {:select_hand, _} -> true
        _ -> false
      end)

    assigns =
      assigns
      |> assign(:legal_plays, legal_plays)
      |> assign(:can_select_hand, can_select_hand)

    ~H"""
    <div class="bg-green-800 rounded-xl p-4 shadow-lg relative">
      <%= if @waiting do %>
        <.waiting_table room={@room} users={@users} show_seat_selectors={@show_seat_selectors} />
      <% else %>
        <%!-- God Mode Toggle --%>
        <button
          phx-click="select_position"
          phx-value-position={if @god_mode, do: "south", else: "all"}
          class={[
            "absolute top-4 right-4 px-2 py-1 text-xs rounded border transition-colors z-10",
            if(@god_mode,
              do: "bg-yellow-500 text-black border-yellow-600",
              else: "bg-green-700 text-green-100 border-green-600 hover:bg-green-600"
            )
          ]}
        >
          {if @god_mode, do: "👁 God Mode On", else: "👁 God Mode Off"}
        </button>

        <%!-- North --%>
        <div class="flex justify-center mb-4">
          <.hand
            cards={get_hand(@game_state, :north)}
            position={:north}
            player_name={get_player_name(@room, @users, :north)}
            is_current_turn={get_current_turn(@game_state) == :north}
            is_human={@selected_position == :north}
            is_bot={is_bot(@bot_configs, :north)}
            show_cards={@god_mode or @selected_position == :north}
            legal_plays={if @selected_position == :north, do: @legal_plays, else: []}
            trump_suit={get_trump_suit(@game_state)}
            is_cold={player_is_cold?(@game_state, :north)}
            is_dealer={get_dealer(@game_state) == :north}
            selected_cards={if @selected_position == :north, do: @selected_hand_cards, else: []}
            can_select={@can_select_hand and @selected_position == :north}
          />
        </div>
        <%!-- West - Center - East --%>
        <div class="flex justify-between items-start mb-4 gap-4">
          <div class="w-40 flex-none">
            <.hand
              cards={get_hand(@game_state, :west)}
              position={:west}
              player_name={get_player_name(@room, @users, :west)}
              is_current_turn={get_current_turn(@game_state) == :west}
              is_human={@selected_position == :west}
              is_bot={is_bot(@bot_configs, :west)}
              show_cards={@god_mode or @selected_position == :west}
              legal_plays={if @selected_position == :west, do: @legal_plays, else: []}
              trump_suit={get_trump_suit(@game_state)}
              is_cold={player_is_cold?(@game_state, :west)}
              is_dealer={get_dealer(@game_state) == :west}
              orientation={:vertical}
              selected_cards={if @selected_position == :west, do: @selected_hand_cards, else: []}
              can_select={@can_select_hand and @selected_position == :west}
            />
          </div>

          <div class="flex-1 min-w-[300px]">
            <%= case @game_state.phase do %>
              <% :dealer_selection -> %>
                <div class="bg-green-700 rounded-lg p-8 min-h-[200px] flex flex-col items-center justify-center text-center border-2 border-dashed border-green-600">
                  <h3 class="text-xl text-green-100 font-bold mb-4">Dealer Selection</h3>
                  <button
                    phx-click="execute_action"
                    phx-value-action={Jason.encode!("select_dealer")}
                    class="px-6 py-3 bg-yellow-500 hover:bg-yellow-400 text-yellow-900 font-bold rounded-lg shadow-lg transform transition hover:scale-105"
                  >
                    Select Dealer
                  </button>
                </div>
              <% :bidding -> %>
                <div class="bg-green-700/90 p-2 rounded-lg">
                  <.bidding_panel
                    current_bid={get_current_bid(@game_state)}
                    bidder={get_current_bidder(@game_state)}
                    legal_actions={@legal_actions}
                    bid_history={get_bid_history(@game_state)}
                  />
                </div>
              <% :declaring -> %>
                <div class="bg-green-700/90 p-2 rounded-lg">
                  <.trump_selection_panel
                    legal_actions={@legal_actions}
                    hand={get_hand(@game_state, @selected_position)}
                  />
                </div>
              <% :second_deal when @can_select_hand -> %>
                <div class="bg-green-700/90 p-2 rounded-lg">
                  <.hand_selection_panel
                    selected_count={length(@selected_hand_cards)}
                    target_count={6}
                    can_submit={length(@selected_hand_cards) == 6}
                  />
                </div>
              <% _ -> %>
                <.trick_area
                  trick={get_current_trick(@game_state)}
                  leader={trick_leader(@game_state)}
                  winner={trick_winner(@game_state)}
                  trump_suit={get_trump_suit(@game_state)}
                  trick_number={get_trick_number(@game_state)}
                  points_in_trick={
                    calculate_trick_points(
                      get_current_trick(@game_state),
                      get_trump_suit(@game_state)
                    )
                  }
                />
            <% end %>
          </div>

          <div class="w-40 flex-none">
            <.hand
              cards={get_hand(@game_state, :east)}
              position={:east}
              player_name={get_player_name(@room, @users, :east)}
              is_current_turn={get_current_turn(@game_state) == :east}
              is_human={@selected_position == :east}
              is_bot={is_bot(@bot_configs, :east)}
              show_cards={@god_mode or @selected_position == :east}
              legal_plays={if @selected_position == :east, do: @legal_plays, else: []}
              trump_suit={get_trump_suit(@game_state)}
              is_cold={player_is_cold?(@game_state, :east)}
              is_dealer={get_dealer(@game_state) == :east}
              orientation={:vertical}
              align={:end}
              selected_cards={if @selected_position == :east, do: @selected_hand_cards, else: []}
              can_select={@can_select_hand and @selected_position == :east}
            />
          </div>
        </div>
        <%!-- South --%>
        <div class="flex justify-center">
          <.hand
            cards={get_hand(@game_state, :south)}
            position={:south}
            player_name={get_player_name(@room, @users, :south)}
            is_current_turn={get_current_turn(@game_state) == :south}
            is_human={@selected_position == :south}
            is_bot={is_bot(@bot_configs, :south)}
            show_cards={@god_mode or @selected_position == :south}
            legal_plays={if @selected_position == :south, do: @legal_plays, else: []}
            trump_suit={get_trump_suit(@game_state)}
            is_cold={player_is_cold?(@game_state, :south)}
            is_dealer={get_dealer(@game_state) == :south}
            selected_cards={if @selected_position == :south, do: @selected_hand_cards, else: []}
            can_select={@can_select_hand and @selected_position == :south}
          />
        </div>
        <%!-- Game info bar --%>
        <div class="mt-4 bg-green-900 rounded p-2 text-white text-sm flex justify-between">
          <span>Trump: {format_trump(get_trump_suit(@game_state))}</span>
          <span>Hand #{get_hand_number(@game_state)}</span>
          <span>
            N/S: {get_score(@game_state, :north_south)} | E/W: {get_score(@game_state, :east_west)}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  # =============================================================================
  # Waiting Table Component (Pre-game state with seat selection)
  # =============================================================================

  @doc """
  Renders the card table in waiting state with seat selection dropdowns.

  ## Attributes

  - `room` - Room struct with positions map
  - `users` - List of available users for selection
  - `show_seat_selectors` - Whether to show dropdown selectors

  ## Examples

      <.waiting_table room={@room} users={@users} show_seat_selectors={true} />
  """
  attr :room, :map, default: nil
  attr :users, :list, default: []
  attr :show_seat_selectors, :boolean, default: false

  def waiting_table(assigns) do
    filled_seats = count_filled_seats(assigns.room)
    assigns = assign(assigns, :filled_seats, filled_seats)

    ~H"""
    <div class="relative min-h-[400px]">
      <%!-- North seat --%>
      <div class="flex justify-center mb-8">
        <.seat_panel
          position={:north}
          room={@room}
          users={@users}
          show_seat_selectors={@show_seat_selectors}
        />
      </div>

      <%!-- West - Center - East --%>
      <div class="flex justify-between items-center mb-8 gap-4">
        <div class="w-48 flex-none">
          <.seat_panel
            position={:west}
            room={@room}
            users={@users}
            show_seat_selectors={@show_seat_selectors}
          />
        </div>

        <div class="flex-1 min-w-[300px]">
          <div class="bg-green-700 rounded-lg p-6 min-h-[180px] flex flex-col items-center justify-center text-center border-2 border-dashed border-green-600">
            <h3 class="text-xl text-green-100 font-bold mb-2">Waiting for Players</h3>
            <p class="text-green-200 text-sm mb-3">
              {@filled_seats} / 4 seats filled
            </p>
            <div class="flex gap-3 mb-3">
              <%= for position <- [:north, :east, :south, :west] do %>
                <div class="flex flex-col items-center gap-1">
                  <div class={[
                    "w-4 h-4 rounded-full",
                    if(seat_filled?(@room, position),
                      do: "bg-green-400",
                      else: "bg-green-900 border-2 border-green-500"
                    )
                  ]}>
                  </div>
                  <span class="text-xs text-green-300">{position_abbrev(position)}</span>
                </div>
              <% end %>
            </div>
            <%= if @filled_seats == 4 do %>
              <p class="text-yellow-300 text-sm animate-pulse">
                All seats filled! Game starting...
              </p>
            <% else %>
              <p class="text-green-300/70 text-xs mt-2">
                Open seats can be joined by mobile players
              </p>
            <% end %>
          </div>
        </div>

        <div class="w-48 flex-none">
          <.seat_panel
            position={:east}
            room={@room}
            users={@users}
            show_seat_selectors={@show_seat_selectors}
          />
        </div>
      </div>

      <%!-- South seat --%>
      <div class="flex justify-center">
        <.seat_panel
          position={:south}
          room={@room}
          users={@users}
          show_seat_selectors={@show_seat_selectors}
        />
      </div>
    </div>
    """
  end

  # =============================================================================
  # Seat Panel Component
  # =============================================================================

  @doc """
  Renders a single seat position with optional player selector dropdown.

  ## Attributes

  - `position` - Seat position (:north | :south | :east | :west)
  - `room` - Room struct with positions map
  - `users` - List of available users
  - `show_seat_selectors` - Whether to show the dropdown selector
  """
  attr :position, :atom, required: true
  attr :room, :map, default: nil
  attr :users, :list, default: []
  attr :show_seat_selectors, :boolean, default: false

  def seat_panel(assigns) do
    current_user_id = get_seat_user_id(assigns.room, assigns.position)
    player_name = get_player_name(assigns.room, assigns.users, assigns.position)

    assigns =
      assigns
      |> assign(:current_user_id, current_user_id)
      |> assign(:player_name, player_name)
      |> assign(:is_filled, not is_nil(current_user_id))

    ~H"""
    <div class={[
      "bg-gray-800 rounded-lg p-3 shadow-md min-w-[140px]",
      if(@is_filled, do: "ring-2 ring-green-500", else: "ring-1 ring-gray-600")
    ]}>
      <div class="text-xs font-semibold uppercase tracking-wide text-gray-400 mb-2 text-center">
        {position_label(@position)}
      </div>

      <%= if @show_seat_selectors do %>
        <form phx-change="assign_seat" phx-value-position={@position}>
          <select
            id={"seat-selector-#{@position}"}
            name="user_id"
            aria-label={"Select player for #{position_label(@position)} seat"}
            class="w-full text-xs bg-gray-700 border-gray-600 text-white rounded-md px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-green-500"
          >
            <option value="empty" selected={is_nil(@current_user_id)}>
              — Empty Seat —
            </option>
            <%= for user <- @users do %>
              <option value={user.id} selected={@current_user_id == user.id}>
                {user_display_name(user)}
              </option>
            <% end %>
          </select>
        </form>
      <% else %>
        <div class="text-sm text-center text-white">
          {@player_name || "Empty"}
        </div>
      <% end %>
    </div>
    """
  end

  defp count_filled_seats(nil), do: 0

  defp count_filled_seats(%{positions: positions}) when is_map(positions) do
    positions
    |> Enum.count(fn {_pos, user_id} -> not is_nil(user_id) end)
  end

  defp count_filled_seats(_), do: 0

  defp seat_filled?(nil, _position), do: false

  defp seat_filled?(%{positions: positions}, position) when is_map(positions) do
    not is_nil(Map.get(positions, position))
  end

  defp seat_filled?(_, _), do: false

  defp get_seat_user_id(nil, _position), do: nil

  defp get_seat_user_id(%{positions: positions}, position) when is_map(positions) do
    Map.get(positions, position)
  end

  defp get_seat_user_id(_, _), do: nil

  defp get_player_name(nil, _users, _position), do: nil

  defp get_player_name(%{positions: positions}, users, position)
       when is_map(positions) and is_list(users) do
    case Map.get(positions, position) do
      nil ->
        nil

      user_id ->
        users
        |> Enum.find(&(&1.id == user_id))
        |> case do
          nil -> String.slice(user_id, 0, 8)
          user -> user_display_name(user)
        end
    end
  end

  defp get_player_name(_, _, _), do: nil

  defp user_display_name(user) do
    user.username || user.email || String.slice(user.id, 0, 8)
  end

  # =============================================================================
  # Bidding Panel Component
  # =============================================================================

  @doc """
  Renders bidding phase UI with bid buttons.

  ## Attributes

  - `current_bid` - Current high bid amount
  - `bidder` - Position that made the high bid
  - `legal_actions` - List of legal bidding actions
  - `bid_history` - List of previous bids

  ## Examples

      <.bidding_panel
        current_bid={8}
        bidder={:north}
        legal_actions={[{:bid, 9}, {:bid, 10}, :pass]}
        bid_history={[{:north, 8}, {:east, :pass}]}
      />
  """
  attr :current_bid, :integer, default: nil
  attr :bidder, :atom, default: nil
  attr :legal_actions, :list, default: []
  attr :bid_history, :list, default: []

  def bidding_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-lg p-4 shadow">
      <h3 class="font-bold mb-2 text-lg">Bidding Phase</h3>

      <div class="mb-4">
        <%= if @current_bid do %>
          <p>
            Current bid: <span class="font-bold text-xl">{@current_bid}</span> by {@bidder}
          </p>
        <% else %>
          <p class="text-gray-500">No bids yet</p>
        <% end %>
      </div>

      <div class="flex flex-wrap gap-2 mb-4">
        <%= for action <- @legal_actions do %>
          <%= case action do %>
            <% {:bid, amount} -> %>
              <button
                phx-click="execute_action"
                phx-value-action={Jason.encode!(["bid", amount])}
                class="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600 font-medium"
              >
                Bid {amount}
              </button>
            <% :pass -> %>
              <button
                phx-click="execute_action"
                phx-value-action={Jason.encode!("pass")}
                class="px-4 py-2 bg-gray-300 text-gray-700 rounded hover:bg-gray-400"
              >
                Pass
              </button>
            <% _ -> %>
          <% end %>
        <% end %>
      </div>

      <div class="text-sm text-gray-600">
        <p class="font-medium">Bid History:</p>
        <%= for {position, bid} <- @bid_history do %>
          <p>{position}: {format_bid(bid)}</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_bid(:pass), do: "Pass"
  defp format_bid(amount) when is_integer(amount), do: "Bid #{amount}"
  defp format_bid(_), do: "Unknown"

  # =============================================================================
  # Trump Selection Panel Component
  # =============================================================================

  @doc """
  Renders trump selection UI with suit buttons.

  ## Attributes

  - `legal_actions` - List of legal declare_trump actions
  - `hand` - Player's hand to show suit counts

  ## Examples

      <.trump_selection_panel
        legal_actions={[{:declare_trump, :hearts}, {:declare_trump, :spades}]}
        hand={[{14, :hearts}, {13, :hearts}, {5, :spades}]}
      />
  """
  attr :legal_actions, :list, default: []
  attr :hand, :list, default: []

  def trump_selection_panel(assigns) do
    suit_counts = count_suits(assigns.hand)
    assigns = assign(assigns, :suit_counts, suit_counts)

    ~H"""
    <div class="bg-white rounded-lg p-4 shadow">
      <h3 class="font-bold mb-2 text-lg">Choose Trump Suit</h3>
      <p class="text-sm text-gray-600 mb-4">You won the bid! Select the trump suit.</p>

      <div class="grid grid-cols-2 gap-4">
        <%= for {:declare_trump, suit} <- @legal_actions do %>
          <button
            phx-click="execute_action"
            phx-value-action={Jason.encode!(["declare_trump", suit])}
            class={[
              "p-4 rounded-lg border-2 hover:border-blue-500 transition-colors",
              suit_button_color(suit)
            ]}
          >
            <div class="text-4xl">{suit_symbol(suit)}</div>
            <div class="text-sm font-medium">{suit}</div>
            <div class="text-xs text-gray-500">{Map.get(@suit_counts, suit, 0)} cards</div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp suit_button_color(suit) when suit in [:hearts, :diamonds],
    do: "text-red-600 border-red-300"

  defp suit_button_color(_), do: "text-gray-900 border-gray-300"

  # =============================================================================
  # Hand Selection Panel Component
  # =============================================================================

  @doc """
  Renders UI for selecting cards to keep (dealer robs pack).

  ## Attributes

  - `selected_count` - Number of cards currently selected
  - `target_count` - Number of cards to select (usually 6)
  - `can_submit` - Boolean, true if selection is complete

  ## Examples

      <.hand_selection_panel
        selected_count={6}
        target_count={6}
        can_submit={true}
      />
  """
  attr :selected_count, :integer, default: 0
  attr :target_count, :integer, default: 6
  attr :can_submit, :boolean, default: false

  def hand_selection_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-lg p-4 shadow text-center">
      <h3 class="font-bold mb-2 text-lg">Select Hand</h3>
      <p class="text-sm text-gray-600 mb-4">
        Choose exactly {@target_count} cards to keep.
      </p>

      <div class="mb-4">
        <span class={[
          "text-2xl font-bold",
          if(@selected_count == @target_count, do: "text-green-600", else: "text-gray-800")
        ]}>
          {@selected_count} / {@target_count}
        </span>
        <span class="text-sm text-gray-500 ml-1">selected</span>
      </div>

      <button
        phx-click="submit_hand_selection"
        disabled={not @can_submit}
        class={[
          "px-6 py-2 rounded font-medium transition-colors",
          if(@can_submit,
            do: "bg-green-500 text-white hover:bg-green-600",
            else: "bg-gray-300 text-gray-500 cursor-not-allowed"
          )
        ]}
      >
        Confirm Selection
      </button>
    </div>
    """
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp extract_legal_plays(actions) do
    actions
    |> Enum.filter(fn
      {:play_card, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:play_card, card} -> card end)
  end

  defp get_hand(state, position) do
    with %{players: players} <- state,
         %{hand: hand} <- Map.get(players, position) do
      hand
    else
      _ -> []
    end
  end

  defp get_dealer(state) do
    Map.get(state, :current_dealer)
  end

  defp get_current_turn(state) do
    Map.get(state, :current_turn)
  end

  defp get_trump_suit(state) do
    Map.get(state, :trump_suit)
  end

  defp player_is_cold?(state, position) do
    with %{players: players} <- state,
         player when is_map(player) <- Map.get(players, position) do
      Map.get(player, :eliminated?, Map.get(player, :cold, false))
    else
      _ -> false
    end
  end

  defp get_current_trick(state) do
    case Map.get(state, :current_trick) do
      %{plays: plays} when is_list(plays) ->
        Enum.map(plays, fn {pos, card} -> %{position: pos, card: card} end)

      trick when is_list(trick) ->
        trick

      _ ->
        []
    end
  end

  defp trick_leader(state) do
    case Map.get(state, :current_trick) do
      %{leader: leader} ->
        leader

      _ ->
        case get_current_trick(state) do
          [%{position: leader} | _] -> leader
          _ -> nil
        end
    end
  end

  defp trick_winner(state) do
    case Map.get(state, :current_trick) do
      %{winner: winner} -> winner
      _ -> nil
    end
  end

  defp get_trick_number(state) do
    case Map.get(state, :current_trick) do
      %{number: number} -> number
      _ -> Map.get(state, :trick_number, 1)
    end
  end

  defp calculate_trick_points(trick, trump_suit) do
    trick
    |> Enum.map(fn
      %{card: card} -> point_value(card, trump_suit)
      _ -> 0
    end)
    |> Enum.sum()
  end

  defp get_hand_number(state) do
    Map.get(state, :hand_number, 1) || 1
  end

  defp get_score(state, team) do
    case Map.get(state, :cumulative_scores) do
      scores when is_map(scores) -> Map.get(scores, team, 0)
      _ -> 0
    end
  end

  defp is_bot(bot_configs, position) do
    case Map.get(bot_configs, position) do
      %{type: :bot} -> true
      _ -> false
    end
  end

  defp get_current_bid(state) do
    case Map.get(state, :highest_bid) do
      {_position, amount} -> amount
      _ -> nil
    end
  end

  defp get_current_bidder(state) do
    case Map.get(state, :highest_bid) do
      {position, _amount} -> position
      _ -> nil
    end
  end

  defp get_bid_history(state) do
    Map.get(state, :bids, [])
  end
end

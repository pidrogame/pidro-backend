defmodule PidroServerWeb.PlayPageHTML do
  @moduledoc "HTML template for a player's share page."

  use PidroServerWeb, :html

  import PidroServerWeb.InvitePageHTML, only: [store_badges: 1]

  embed_templates "play_page_html/*"
end

# A resident whose Telegram bot posts inline-button cards from outside the house
# (a home runtime on its own machine) needs the taps on those buttons to reach it.
# The house owns the bot's webhook, so until now every callback_data other than
# safeguard_reset: was dropped and the button spun forever. These two columns
# name where the house forwards such taps and the shared secret it signs them
# with. Both blank: nothing is forwarded, as before. The house never decides what
# a tap means; the resident does, with the tapping user's id in hand.
class AddTelegramCallbackForwardToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :telegram_callback_forward_url, :string
    add_column :agents, :telegram_callback_forward_secret, :string
  end

end

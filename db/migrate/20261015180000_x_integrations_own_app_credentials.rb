class XIntegrationsOwnAppCredentials < ActiveRecord::Migration[8.1]

  # An account without a site admin posts through its own X app; the house
  # app (Rails credentials) is only for accounts with a site admin in them.
  # The daily post ceiling goes: each account pays X for its own posts.
  def change
    add_column :x_integrations, :client_id, :string
    add_column :x_integrations, :client_secret, :text
    remove_column :x_integrations, :daily_post_limit, :integer, null: false, default: 20
  end

end

# A reflex that exists is live (#538): no shadow mode, no switch.
class RemoveLiveFromReflexes < ActiveRecord::Migration[8.1]

  def change
    remove_column :reflexes, :live, :boolean, default: false, null: false
  end

end

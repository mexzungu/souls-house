# A retried activation reuses its placement with the next generation
# (docs/2026-10-10-vm-imports.md, point 8). Each purchase records the
# generation it was made for, so an attempt never reads the last attempt's
# deleted server as its own. Every existing purchase belongs to generation 1:
# nothing has been retried before this.
class AddPlacementGenerationToCloudProcurementOperations < ActiveRecord::Migration[8.1]

  def change
    add_column :cloud_procurement_operations, :placement_generation, :integer, null: false, default: 1
    add_check_constraint :cloud_procurement_operations, "placement_generation >= 1",
      name: "cloud_procurement_operations_positive_placement_generation"
  end

end

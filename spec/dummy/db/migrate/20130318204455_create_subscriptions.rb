class CreateSubscriptions < ActiveRecord::Migration
  def change
    create_table :subscriptions do |t|
      t.string :stripe_id
      t.integer :plan_id
      t.integer :coupon_id
      t.string :last_four
      t.string :expiry_month
      t.string :expiry_year
      t.string :card_type
      t.float :current_price
      t.integer :customer_id

      t.timestamps
    end
  end
end

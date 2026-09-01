class CreateAvailabilityRules < ActiveRecord::Migration[8.1]
  def change
    create_table :availability_rules do |t|
      # user_id が NULL ならテナント全体ルール、値があれば個人ルール
      # （仕様書 §3.3(4)。scope カラムは持たない）
      t.references :user, null: true, foreign_key: true, index: false
      t.integer :day_of_week, null: false               # 0-6
      t.time    :start_time,  null: false
      t.time    :end_time,    null: false
      t.string  :rule_type,   null: false               # allow / block
      t.string  :label                                  # NULL可, 表示用の理由

      t.timestamps
    end

    # ルール引き当て（仕様書 §3.2）
    add_index :availability_rules, [:user_id, :day_of_week]
  end
end

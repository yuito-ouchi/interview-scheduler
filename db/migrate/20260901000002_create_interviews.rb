class CreateInterviews < ActiveRecord::Migration[8.1]
  def change
    create_table :interviews do |t|
      t.string   :candidate_name, null: false
      t.datetime :start_at,       null: false
      t.datetime :end_at,         null: false
      t.string   :location_type,  null: false          # online / onsite
      t.string   :location_text                        # NULL可
      t.string   :meet_url                             # NULL可
      t.references :created_by, null: false,
                   foreign_key: { to_table: :users }   # 登録した採用担当者

      t.timestamps
    end

    # 一覧の日時順ソート（仕様書 §3.2）
    add_index :interviews, :start_at
  end
end

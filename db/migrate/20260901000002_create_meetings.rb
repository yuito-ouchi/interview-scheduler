class CreateMeetings < ActiveRecord::Migration[8.1]
  def change
    create_table :meetings do |t|
      t.string   :guest_name,     null: false
      t.datetime :start_at,       null: false
      t.datetime :end_at,         null: false
      t.string   :location_type,  null: false          # online / onsite
      t.string   :location_text                        # NULL可
      t.string   :meet_url                             # NULL可
      t.references :created_by, null: false,
                   foreign_key: { to_table: :users }   # 登録した主催者

      t.timestamps
    end

    # 一覧の日時順ソート（仕様書 §3.2）
    add_index :meetings, :start_at
  end
end

class CreateMeetingAttendees < ActiveRecord::Migration[8.1]
  def change
    create_table :meeting_attendees do |t|
      # 複合 UNIQUE 索引に寄せるため meeting_id 単独索引は張らない
      t.references :meeting, null: false, foreign_key: true, index: false
      t.references :user,    null: false, foreign_key: true

      t.timestamps
    end

    # BR-10（同一メンバーの重複指定禁止）を DB 側で担保（仕様書 §3.2）
    add_index :meeting_attendees, [ :meeting_id, :user_id ], unique: true
  end
end

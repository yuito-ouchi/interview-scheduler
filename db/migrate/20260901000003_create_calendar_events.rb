class CreateCalendarEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :calendar_events do |t|
      # 空き判定の主クエリ用に user_id 単独の索引は張らず、
      # 複合索引 [user_id, start_at] に寄せる（仕様書 §3.2）
      t.references :user, null: false, foreign_key: true, index: false
      t.string   :title,   null: false
      t.datetime :start_at, null: false                # UTC 保存
      t.datetime :end_at,   null: false                # UTC 保存
      t.boolean  :all_day,  null: false, default: false
      t.string   :source,   null: false                # external / app
      # source=app のときのみ値が入る。連動削除用（Phase 2）
      t.references :interview, null: true, foreign_key: true

      t.timestamps
    end

    # 空き判定の主クエリ:
    #   WHERE user_id IN (...) AND start_at < ? AND end_at > ?
    add_index :calendar_events, [:user_id, :start_at]
  end
end

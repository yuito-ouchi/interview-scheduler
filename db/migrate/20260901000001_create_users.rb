class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string  :name,            null: false
      t.string  :email,           null: false
      t.string  :password_digest, null: false
      t.boolean :operator,        null: false, default: false
      t.boolean :participant,     null: false, default: false
      # admin = 設定画面（メンバー管理）を操作できる。operator/participant と
      # 同じく「役割ではなくできること」をフラグで持つ方針を踏襲する（仕様書§6.1）。
      t.boolean :admin,           null: false, default: false

      t.timestamps
    end

    # 同一人物の二重登録防止（仕様書 §3.2）
    add_index :users, :email, unique: true
  end
end

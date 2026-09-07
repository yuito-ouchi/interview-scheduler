class DeviseMigrateUsers < ActiveRecord::Migration[8.1]
  # has_secure_password と Devise の database_authenticatable はどちらも
  # bcrypt ベースでハッシュ形式に互換性があるため、カラムをリネームするだけで
  # 既存（シード含む）のパスワードはそのまま使える（判断メモ D-12）。
  def change
    rename_column :users, :password_digest, :encrypted_password
    change_column_default :users, :encrypted_password, from: nil, to: ""
    change_column_null :users, :encrypted_password, false, ""
    add_column :users, :remember_created_at, :datetime
  end
end

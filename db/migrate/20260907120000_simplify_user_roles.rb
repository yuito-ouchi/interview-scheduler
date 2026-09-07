# 判断メモ D-15：users の3フラグ（operator / participant / admin）を admin だけに
# 減らし、「管理者」と「メンバー（アカウントを持つ全員）」の2区分にする。
#
# operator（＝ログインできる）と participant（＝ミーティングの候補になる）を分けて
# いたのは「兼任がある」ためだったが、実運用では両方 true のアカウントしか作られず、
# 区別が設定項目としてだけ残っていた。アカウントを持つ人＝メンバーとし、
# ログインでき、参加者候補にも並ぶ、という1つの意味に統一する。
class SimplifyUserRoles < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :operator,    :boolean, null: false, default: false
    remove_column :users, :participant, :boolean, null: false, default: false
  end
end

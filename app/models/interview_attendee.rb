class InterviewAttendee < ApplicationRecord
  # 面接と面接官の紐付け。[interview_id, user_id] は DB 側でも UNIQUE
  belongs_to :interview
  belongs_to :user

  # BR-10: 同一メンバーの重複指定禁止（DB の UNIQUE 索引と対）
  validates :user_id, uniqueness: { scope: :interview_id }
end

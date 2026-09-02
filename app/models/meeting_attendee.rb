class MeetingAttendee < ApplicationRecord
  # ミーティングと参加者の紐付け。[meeting_id, user_id] は DB 側でも UNIQUE
  belongs_to :meeting
  belongs_to :user

  # BR-10: 同一メンバーの重複指定禁止（DB の UNIQUE 索引と対）
  validates :user_id, uniqueness: { scope: :meeting_id }
end

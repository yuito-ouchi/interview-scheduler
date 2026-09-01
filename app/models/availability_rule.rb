class AvailabilityRule < ApplicationRecord
  # user_id が NULL ならテナント全体、値があれば個人ルール（仕様書 §3.3(4)）。
  # allow は狭める方向、block は広げる方向にのみ働く（BR-12）
  RULE_TYPES = %w[allow block].freeze

  belongs_to :user, optional: true

  validates :day_of_week, presence: true,
            inclusion: { in: 0..6 }
  validates :rule_type, inclusion: { in: RULE_TYPES }
  validates :start_time, :end_time, presence: true
  validate  :end_after_start

  scope :tenant_wide, -> { where(user_id: nil) }
  scope :personal,    -> { where.not(user_id: nil) }
  scope :allows,      -> { where(rule_type: "allow") }
  scope :blocks,      -> { where(rule_type: "block") }

  private

  def end_after_start
    return if start_time.blank? || end_time.blank?

    errors.add(:end_time, "は開始時刻より後にしてください") if end_time <= start_time
  end
end

class CalendarEvent < ApplicationRecord
  # 時間の占有。source が external（ダミー予定）か app（本ツール作成）か。
  # 判定ロジックは埋まる理由を問わずこのテーブルだけを見る（仕様書 §3.3(2)）
  SOURCES = %w[external app].freeze

  belongs_to :user
  belongs_to :meeting, optional: true

  validates :title,  presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :start_at, :end_at, presence: true
  validate  :end_after_start
  validate  :meeting_only_for_app_source

  scope :external, -> { where(source: "external") }
  scope :app,      -> { where(source: "app") }

  private

  def end_after_start
    return if start_at.blank? || end_at.blank?

    errors.add(:end_at, "は開始時刻より後にしてください") if end_at <= start_at
  end

  # meeting_id は source=app の行にのみ紐づく（仕様書 §3 ER図）
  def meeting_only_for_app_source
    if meeting_id.present? && source != "app"
      errors.add(:meeting_id, "は source=app のときのみ設定できます")
    end
  end
end

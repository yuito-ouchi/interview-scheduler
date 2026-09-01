class Interview < ApplicationRecord
  # 面接の業務記録。時間の占有は calendar_events 側に別レコードとして持つ。
  LOCATION_TYPES = %w[online onsite].freeze

  belongs_to :created_by, class_name: "User", inverse_of: :created_interviews

  has_many :interview_attendees, dependent: :destroy
  has_many :attendees, through: :interview_attendees, source: :user

  # 本ツールが作成した占有（source=app）。面接を消せば占有も消える
  has_many :calendar_events, dependent: :destroy

  validates :candidate_name, presence: true
  validates :location_type, inclusion: { in: LOCATION_TYPES }
  validates :start_at, :end_at, presence: true
  validate  :end_after_start

  scope :upcoming, -> { where(start_at: Time.current..).order(:start_at) }

  # BR-11: 予約タイトルは固定フォーマット。編集不可
  def calendar_title
    "面接：#{candidate_name}様"
  end

  private

  def end_after_start
    return if start_at.blank? || end_at.blank?

    errors.add(:end_at, "は開始時刻より後にしてください") if end_at <= start_at
  end
end

class Meeting < ApplicationRecord
  # ミーティングの業務記録。時間の占有は calendar_events 側に別レコードとして持つ。
  LOCATION_TYPES = %w[online onsite].freeze

  belongs_to :created_by, class_name: "User", inverse_of: :created_meetings

  has_many :meeting_attendees, dependent: :destroy
  has_many :attendees, through: :meeting_attendees, source: :user

  # 本ツールが作成した占有（source=app）。ミーティングを消せば占有も消える
  has_many :calendar_events, dependent: :destroy

  validates :guest_name, presence: true
  validates :location_type, inclusion: { in: LOCATION_TYPES }
  validates :start_at, :end_at, presence: true
  validate  :end_after_start
  # §9.3-1：空き判定は「予定と重なるか」しか見ないため、過去日を指定すると
  # 全員空きと出てしまう。作成時に開始が未来であることを別途担保する。
  validates :start_at, comparison: { greater_than: -> { Time.current },
                                     message: "は現在より後の日時にしてください" },
            on: :create, if: -> { start_at.present? }

  scope :upcoming, -> { where(start_at: Time.current..).order(:start_at) }

  # BR-11: 予約タイトルは固定フォーマット。編集不可
  def calendar_title
    "ミーティング：#{guest_name}様"
  end

  private

  def end_after_start
    return if start_at.blank? || end_at.blank?

    errors.add(:end_at, "は開始時刻より後にしてください") if end_at <= start_at
  end
end

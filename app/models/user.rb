class User < ApplicationRecord
  # operator = ツールを操作する / interviewer = 面接に出る。
  # 兼任があるため役割で分けずフラグで持つ（仕様書 §6.1）
  has_many :calendar_events,     dependent: :destroy
  has_many :availability_rules,  dependent: :destroy

  has_many :interview_attendees, dependent: :destroy
  has_many :interviews, through: :interview_attendees

  has_many :created_interviews, class_name: "Interview",
           foreign_key: :created_by_id, inverse_of: :created_by,
           dependent: :restrict_with_exception

  validates :name,  presence: true
  validates :email, presence: true, uniqueness: { case_sensitive: false }

  scope :operators,    -> { where(operator: true) }
  scope :interviewers, -> { where(interviewer: true) }
end

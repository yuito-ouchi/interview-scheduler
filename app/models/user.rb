class User < ApplicationRecord
  # アカウントを持つ人＝メンバー。ログインでき、ミーティングの参加者候補にも並ぶ。
  # 区別はこの上に乗る admin（設定画面を操作できる）1つだけ（判断メモ D-15）。
  # かつては operator（操作する）/ participant（出る）を分けていたが、兼任前提で
  # 両方 true のアカウントしか作られず、区別が設定項目としてだけ残っていた。
  #
  # 認証はDevise（判断メモ D-12。旧D-1のhas_secure_passwordから移行）。
  # :confirmable は入れない（確認メール不要という要件そのもの）。:recoverable も
  # 入れない（パスワードリセットメールを送るメール基盤が無く、依頼にも無い範囲）。
  devise :database_authenticatable, :registerable, :rememberable, :validatable

  has_many :calendar_events,     dependent: :destroy
  has_many :availability_rules,  dependent: :destroy

  has_many :meeting_attendees, dependent: :destroy
  has_many :meetings, through: :meeting_attendees

  has_many :created_meetings, class_name: "Meeting",
           foreign_key: :created_by_id, inverse_of: :created_by,
           dependent: :restrict_with_exception

  validates :name, presence: true
  # email の presence/uniqueness/形式チェックは :validatable が提供する

  scope :admins, -> { where(admin: true) }
end

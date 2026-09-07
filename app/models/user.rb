class User < ApplicationRecord
  # operator = ツールを操作する / participant = ミーティングに出る / admin = 設定画面を操作できる。
  # 兼任があるため役割で分けずフラグで持つ（仕様書 §6.1）
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

  scope :operators,    -> { where(operator: true) }
  scope :participants, -> { where(participant: true) }
  scope :admins,       -> { where(admin: true) }

  # 認証の入口そのものを operator に絞る（旧 SessionsController#create の
  # `User.find_by(email:, operator: true)` と同じ制約）。participant限定の
  # アカウントはパスワードが合っていてもログインできない、という現行の挙動と
  # セキュリティ姿勢をそのまま保つ（「認証は通るが権限が無い」状態を作らない）。
  def self.find_for_database_authentication(warden_conditions)
    find_by(email: warden_conditions[:email], operator: true)
  end
end

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # ログイン（F-05 / 仕様書 §6.2）。全画面がログインを要求する（Devise標準）。
  # unless: :devise_controller? が無いと、Devise自身のログイン/登録画面
  # （ApplicationControllerを継承する）もこのbefore_actionの対象になり、
  # 「ログインしていないとログイン画面に辿り着けない」無限リダイレクトになる。
  # ログイン前提でよいsessions#new/create・registrations#new/create等の
  # 出し分けはDevise本体が既に正しく行っているため、Deviseのコントローラーは
  # 素通しにする。
  before_action :authenticate_user!, unless: :devise_controller?
  # operator に絞る制約は認証の入口（User.find_for_database_authentication）で
  # ログイン自体を弾いているが、Devise はセッションを毎リクエストDBへ問い合わせ
  # 直すわけではないため、ログイン中に operator を false にされても Warden の
  # セッションはそれだけでは切れない。旧実装（毎リクエスト operator: true を
  # 条件にDBを引き直す current_user）が持っていた「権限を落とした瞬間から
  # 操作不能になる」という性質（仕様書§6.2）を保つため、ここでも毎リクエスト
  # 確認する（判断メモ D-12）。
  before_action :require_operator!, unless: :devise_controller?

  before_action :configure_permitted_parameters, if: :devise_controller?

  protected

  # 主催者・参加者の自己登録（会員登録）で許可するパラメータ。
  # admin は意図的に許可リストへ入れない＝ここがadmin自己付与を防ぐ唯一の境界。
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: %i[name operator participant])
  end

  private

  def require_operator!
    return if current_user.operator?

    sign_out(current_user)
    redirect_to new_user_session_path, alert: "権限が変更されたため、再度ログインしてください"
  end

  # 設定画面（メンバー管理）等、admin だけに許す操作で使う（UsersController）。
  # 毎リクエスト確認する。「メンバーの誰が管理者か」という認可判断はコントローラ側
  # に集約し、ビューでは表示の出し分けにのみ使う。
  def require_admin
    redirect_to root_path, alert: "この操作には管理者権限が必要です" unless current_user&.admin?
  end
end

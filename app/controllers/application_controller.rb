class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # 簡易ログイン（F-05 / 仕様書 §6.2）。全画面が操作者ログインを要求する。
  before_action :require_operator
  helper_method :current_user

  private

  # session の user_id だけで引かず operator: true も課す。
  # session に入れたあとで operator を false にされたユーザーが、
  # ログインしたまま操作を続けられてしまうのを防ぐ。毎リクエスト確認することで
  # 権限を落とした瞬間から操作不能になる（仕様書 §6.2）。
  def current_user
    @current_user ||= User.find_by(id: session[:user_id], operator: true)
  end

  def require_operator
    redirect_to login_path unless current_user
  end
end

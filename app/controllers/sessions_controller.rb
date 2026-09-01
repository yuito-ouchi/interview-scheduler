class SessionsController < ApplicationController
  # ログイン前は current_user が nil なので、この2アクションだけ認証を外す
  skip_before_action :require_operator, only: %i[new create]

  # GET /login
  def new
    @operators = User.where(operator: true).order(:name)
    # ログイン済みなら確認表示。?switch=1 が付いていれば選択フォームを出す（切替）
    @show_picker = @operators.any? && (current_user.nil? || params[:switch].present?)
  end

  # POST /login
  def create
    # id と operator: true の両方で引く（仕様書 §6.2）。存在しない id や
    # operator でない id を渡されても user は nil になる。
    user = User.find_by(id: params[:user_id], operator: true)

    if user
      session[:user_id] = user.id
      redirect_to root_path, status: :see_other
    else
      redirect_to login_path, alert: "操作者を選択してください", status: :see_other
    end
  end
end

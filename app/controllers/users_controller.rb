class UsersController < ApplicationController
  # 設定画面（メンバー管理・F-01/F-02）。ロール制御の確認用に admin 限定にする。
  before_action :require_admin
  before_action :set_user, only: %i[edit update destroy]

  # GET /users
  def index
    @users = User.order(:name)
  end

  # GET /users/new
  def new
    @user = User.new
  end

  # POST /users
  def create
    @user = User.new(user_params)

    if @user.save
      redirect_to users_path, notice: "#{@user.name} を追加しました"
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /users/:id/edit
  def edit
  end

  # PATCH /users/:id
  def update
    if @user.update(update_params)
      redirect_to users_path, notice: "#{@user.name} を更新しました"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /users/:id
  def destroy
    if @user == current_user
      redirect_to users_path, alert: "自分自身は削除できません", status: :see_other
      return
    end

    # meeting_attendees は dependent: :destroy のため、ガード無しだと今後の
    # ミーティングに出席予定の人を削除した瞬間、そのミーティングから黙って
    # 出席者と占有（calendar_events）だけが消える（ミーティング本体は残る）。
    # created_meetings（登録者）と違いDB制約が無いため、ここでアプリ側から止める（D-8）。
    if @user.meetings.upcoming.exists?
      redirect_to users_path,
        alert: "#{@user.name} は今後のミーティングに参加者として登録されているため削除できません",
        status: :see_other
      return
    end

    # created_meetings が dependent: :restrict_with_exception のため、
    # 登録者になっているミーティングが残っていると削除できない（意図的）。
    @user.destroy
    redirect_to users_path, notice: "#{@user.name} を削除しました", status: :see_other
  rescue ActiveRecord::DeleteRestrictionError
    redirect_to users_path,
      alert: "#{@user.name} は登録者になっているミーティングが残っているため削除できません",
      status: :see_other
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    params.expect(user: %i[name email password admin])
  end

  # 編集時のパスワードは空欄なら変更しない（空文字を送って上書きしないための対応）。
  def update_params
    permitted = user_params
    permitted = permitted.except(:password) if permitted[:password].blank?
    permitted
  end
end

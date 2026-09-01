require "test_helper"

# 簡易ログイン（F-05 / 仕様書 §6.2）。パスワード認証はしない。
class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @operator     = User.create!(name: "採用 花子", email: "op1@example.com", operator: true)
    @operator2    = User.create!(name: "調整 太郎", email: "op2@example.com", operator: true)
    @interviewer  = User.create!(name: "面接 次郎", email: "iv@example.com", operator: false, interviewer: true)
  end

  test "new は operator だけを選択肢に出す" do
    get login_path
    assert_response :success
    assert_select "select#user_id option", text: @operator.name
    assert_select "select#user_id option", text: @operator2.name
    assert_select "select#user_id option", text: @interviewer.name, count: 0
  end

  test "create は operator ならセッションに乗せて root へ" do
    post login_path, params: { user_id: @operator.id }
    assert_redirected_to root_path
    assert_equal @operator.id, session[:user_id]
  end

  test "create は operator でない user_id を弾く" do
    post login_path, params: { user_id: @interviewer.id }
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_equal "操作者を選択してください", flash[:alert]
  end

  test "create は存在しない id・空を弾く" do
    post login_path, params: { user_id: "" }
    assert_redirected_to login_path
    assert_nil session[:user_id]

    post login_path, params: { user_id: 999_999 }
    assert_nil session[:user_id]
  end

  test "未ログインで保護ページ（root = interviews#new）を開くと login へ飛ぶ" do
    get root_path
    assert_redirected_to login_path
  end

  test "ログイン後は保護ページを開ける" do
    post login_path, params: { user_id: @operator.id }
    get new_interview_path
    assert_response :success
  end

  test "operator を後から false にされたら、その時点でログイン状態が切れる（§6.2 の二重条件）" do
    post login_path, params: { user_id: @operator.id }
    assert_equal @operator.id, session[:user_id]

    # ログイン済みなので確認表示になる
    get login_path
    assert_select "form[action=?]", login_path, count: 0
    assert_match(/操作中です/, @response.body)

    @operator.update!(operator: false)

    # current_user が nil に落ち、選択フォームが戻る（session の id はまだ残っている）
    get login_path
    assert_response :success
    assert_select "form[action=?]", login_path
    assert_select "select#user_id"
  end

  test "ログイン済みでも ?switch=1 なら選択フォームを出す（切替）" do
    post login_path, params: { user_id: @operator.id }

    get login_path(switch: 1)
    assert_response :success
    assert_select "select#user_id"
  end
end

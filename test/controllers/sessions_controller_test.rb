require "test_helper"

# ログイン（F-05 / 仕様書 §6.2）。Devise（判断メモ D-12）。
# ここだけは Devise::Test::IntegrationHelpers#sign_in を使わず、実際に
# user_session_path へ POST する（ログインフロー自体を検証する対象のため）。
class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @operator     = User.create!(name: "採用 花子", email: "op1@example.com", password: "password1234", operator: true)
    @operator2    = User.create!(name: "調整 太郎", email: "op2@example.com", password: "password1234", operator: true)
    @participant  = User.create!(name: "参加 次郎", email: "iv@example.com", password: "password1234", operator: false, participant: true)
  end

  test "new は未ログインならログインフォームを出す" do
    get new_user_session_path
    assert_response :success
    assert_select "input#user_email"
    assert_select "input#user_password"
  end

  test "create は email + 正しい password の operator ならログインしてrootへ" do
    post user_session_path, params: { user: { email: @operator.email, password: "password1234" } }
    assert_redirected_to root_path

    get root_path
    assert_response :success
  end

  # Devise標準の失敗時挙動：リダイレクトではなく sessions#new を422で描き直す
  # （Warden::Manager のfailure app。判断メモ D-12）。
  test "create はパスワードが違えば弾く" do
    post user_session_path, params: { user: { email: @operator.email, password: "wrong-password" } }
    assert_response :unprocessable_entity
    assert_match(/メールまたはパスワードが違います/, response.body)

    get root_path
    assert_redirected_to new_user_session_path
  end

  test "create は operator でない人はパスワードが合っていても弾く" do
    post user_session_path, params: { user: { email: @participant.email, password: "password1234" } }
    assert_response :unprocessable_entity

    get root_path
    assert_redirected_to new_user_session_path
  end

  test "create は存在しないメールアドレス・空を弾く" do
    post user_session_path, params: { user: { email: "", password: "" } }
    assert_response :unprocessable_entity

    post user_session_path, params: { user: { email: "nobody@example.com", password: "password1234" } }
    assert_response :unprocessable_entity
  end

  test "未ログインで保護ページ（root = meetings#new）を開くと login へ飛ぶ" do
    get root_path
    assert_redirected_to new_user_session_path
  end

  test "ログイン後は保護ページを開ける" do
    post user_session_path, params: { user: { email: @operator.email, password: "password1234" } }
    get new_meeting_path
    assert_response :success
  end

  test "operator を後から false にされたら、その時点でログイン状態が切れる（§6.2 の二重条件）" do
    post user_session_path, params: { user: { email: @operator.email, password: "password1234" } }
    get root_path
    assert_response :success

    @operator.update!(operator: false)

    # Devise は毎リクエストDBを引き直すわけではないため、application_controller.rb の
    # require_operator! が無いとここで通ってしまう（判断メモ D-12）。
    get root_path
    assert_redirected_to new_user_session_path
  end

  test "destroy はセッションを破棄する" do
    post user_session_path, params: { user: { email: @operator.email, password: "password1234" } }
    delete destroy_user_session_path
    assert_redirected_to root_path # Devise標準：sign_out後はroot_pathへ

    get root_path
    assert_redirected_to new_user_session_path # rootも認証必須なので、そのままlogin待ちになる
  end
end

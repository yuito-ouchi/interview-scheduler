require "test_helper"

# 主催者・参加者の自己登録（会員登録・判断メモ D-12）。
# admin を自己登録では絶対に付与できないこと、確認メール不要で即ログイン
# 状態になること、自己アカウント削除が無効化されていることが主眼。
class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  def sign_up_params(**over)
    { user: { name: "新規 太郎", email: "new@example.com", password: "password1234",
              operator: true, participant: true }.merge(over) }
  end

  test "会員登録で operator: true, participant: true のユーザーが作られ、即ログイン状態になる" do
    assert_difference "User.count", 1 do
      post user_registration_path, params: sign_up_params
    end

    user = User.last
    assert user.operator?
    assert user.participant?
    assert_not user.admin?

    assert_redirected_to root_path
    get root_path
    assert_response :success # 即ログイン状態＝確認メール不要
  end

  test "admin パラメータを紛れ込ませても付与されない" do
    post user_registration_path, params: sign_up_params(admin: true)

    user = User.last
    assert_not user.admin?, "admin は configure_permitted_parameters の許可リストに無いので無視されるはず"
  end

  test "主催者・参加者どちらのチェックも外せば、両方falseで登録できる" do
    post user_registration_path, params: sign_up_params(operator: false, participant: false)

    user = User.last
    assert_not user.operator?
    assert_not user.participant?
  end

  test "自己アカウント削除は無効化されている" do
    user = User.create!(name: "対象 花子", email: "target@example.com", password: "password1234",
                         operator: true, participant: true)
    sign_in user

    assert_no_difference "User.count" do
      delete user_registration_path
    end
    assert_redirected_to root_path
    assert_match(/管理者にご依頼ください/, flash[:alert])
  end
end

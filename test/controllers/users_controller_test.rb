require "test_helper"

# 設定画面（メンバー管理・F-01/F-02）。admin だけが操作できることの確認が主眼。
class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "採用 花子", email: "admin@example.com", password: "password1234",
                           operator: true, admin: true)
    @non_admin = User.create!(name: "調整 太郎", email: "op@example.com", password: "password1234",
                               operator: true, admin: false)
  end

  # sign_in(user) は Devise::Test::IntegrationHelpers（test_helper.rb・判断メモ D-12）

  test "admin は /users を開ける" do
    sign_in @admin
    get users_path
    assert_response :success
    assert_select "table.users-table"
  end

  test "admin でない operator は /users にアクセスできず root へ戻される" do
    sign_in @non_admin
    get users_path
    assert_redirected_to root_path
  end

  test "admin はメンバーを追加できる" do
    sign_in @admin
    assert_difference "User.count", 1 do
      post users_path, params: { user: { name: "新規 太郎", email: "new@example.com",
                                          password: "password1234", participant: true } }
    end
    assert_redirected_to users_path
    assert User.find_by(email: "new@example.com").participant?
  end

  test "admin でない operator はメンバーを追加できない" do
    sign_in @non_admin
    assert_no_difference "User.count" do
      post users_path, params: { user: { name: "新規 太郎", email: "new@example.com",
                                          password: "password1234" } }
    end
    assert_redirected_to root_path
  end

  test "admin はメンバーを編集できる。パスワード欄を空にすれば変更されない" do
    sign_in @admin
    target = User.create!(name: "対象 花子", email: "target@example.com",
                           password: "password1234", participant: true)
    original_digest = target.encrypted_password

    patch user_path(target), params: { user: { name: "対象 花子（改）", email: target.email, password: "" } }

    assert_redirected_to users_path
    target.reload
    assert_equal "対象 花子（改）", target.name
    assert_equal original_digest, target.encrypted_password
  end

  test "admin はメンバーを削除できるが、自分自身は削除できない" do
    sign_in @admin
    target = User.create!(name: "対象 花子", email: "target@example.com", password: "password1234")

    assert_difference "User.count", -1 do
      delete user_path(target)
    end

    assert_no_difference "User.count" do
      delete user_path(@admin)
    end
    assert_equal "自分自身は削除できません", flash[:alert]
  end

  test "登録者になっているメンバーは削除できない（restrict_with_exception）" do
    sign_in @admin
    creator = User.create!(name: "登録者", email: "creator@example.com",
                            password: "password1234", operator: true)
    Meeting.create!(guest_name: "ゲスト", location_type: "online", created_by: creator,
                     start_at: 1.day.from_now, end_at: 1.day.from_now + 1.hour)

    assert_no_difference "User.count" do
      delete user_path(creator)
    end
    assert_match(/削除できません/, flash[:alert])
  end

  test "今後のミーティングに出席予定の参加者は削除できない（D-8）" do
    sign_in @admin
    creator = User.create!(name: "登録者", email: "creator@example.com",
                            password: "password1234", operator: true)
    attendee = User.create!(name: "参加者", email: "attendee@example.com",
                             password: "password1234", participant: true)
    meeting = Meeting.create!(guest_name: "ゲスト", location_type: "online", created_by: creator,
                               start_at: 1.day.from_now, end_at: 1.day.from_now + 1.hour)
    MeetingAttendee.create!(meeting: meeting, user: attendee)

    assert_no_difference "User.count" do
      delete user_path(attendee)
    end
    assert_match(/削除できません/, flash[:alert])
  end

  test "過去のミーティングにしか出席していない参加者は削除できる" do
    sign_in @admin
    creator = User.create!(name: "登録者", email: "creator@example.com",
                            password: "password1234", operator: true)
    attendee = User.create!(name: "参加者", email: "attendee@example.com",
                             password: "password1234", participant: true)
    meeting = Meeting.create!(guest_name: "ゲスト", location_type: "online", created_by: creator,
                               start_at: 1.day.from_now, end_at: 1.day.from_now + 1.hour)
    MeetingAttendee.create!(meeting: meeting, user: attendee)
    meeting.update_columns(start_at: 1.day.ago, end_at: 1.day.ago + 1.hour)

    assert_difference "User.count", -1 do
      delete user_path(attendee)
    end
  end
end

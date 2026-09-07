require "test_helper"

# 設定の子ページ（テナント全体の営業時間＋固定ブロック・判断メモ D-11 / D-13）。
# admin だけが操作できること、常に user_id: nil で保存されること、
# rule_type がフォーム送信値では決まらないことの確認が主眼。
class TenantRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "採用 花子", email: "admin@example.com", password: "password1234",
                           admin: true)
    @non_admin = User.create!(name: "調整 太郎", email: "op@example.com", password: "password1234",
                               admin: false)
  end

  # sign_in(user) は Devise::Test::IntegrationHelpers（test_helper.rb・判断メモ D-12）

  test "admin は /tenant_rules を開ける" do
    sign_in @admin
    get tenant_rules_path
    assert_response :success
    assert_select ".settings-nav__tab.is-active", text: "テナント設定"
  end

  test "admin でないメンバーは /tenant_rules にアクセスできず root へ戻される" do
    sign_in @non_admin
    get tenant_rules_path
    assert_redirected_to root_path
  end

  # --- 1画面への集約（D-13）---------------------------------------------------

  test "index は営業時間と固定ブロックを1画面に出し、ルールの無い曜日は営業日外と表示する" do
    sign_in @admin
    AvailabilityRule.create!(user_id: nil, day_of_week: 1, start_time: "10:00", end_time: "18:00",
                              rule_type: "allow")
    AvailabilityRule.create!(user_id: nil, day_of_week: 1, start_time: "12:00", end_time: "13:00",
                              rule_type: "block", label: "昼休み")

    get tenant_rules_path
    assert_response :success
    assert_select "h2", text: "営業時間"
    assert_select "h2", text: "固定ブロック"
    assert_select "td", text: "10:00–18:00"
    assert_select "td", text: "昼休み"
    # 日〜土のうち allow を登録した月曜以外の6日が「営業日外」
    assert_select "td.is-muted", text: "営業日外", count: 6
  end

  test "index は個人ルールを表示しない（tenant_wide のみ）" do
    sign_in @admin
    member = User.create!(name: "参加 者", email: "p@example.com", password: "password1234")
    AvailabilityRule.create!(user_id: member.id, day_of_week: 1, start_time: "09:00",
                              end_time: "09:30", rule_type: "block", label: "個人の予定")

    get tenant_rules_path
    assert_select "td", text: "個人の予定", count: 0
  end

  # --- 作成 -------------------------------------------------------------------

  test "admin は営業時間を追加できる（user_id は常に nil、rule_type は URL から）" do
    sign_in @admin
    assert_difference "AvailabilityRule.count", 1 do
      post tenant_rules_path(rule_type: "allow"), params: {
        availability_rule: { day_of_week: 3, start_time: "10:00", end_time: "18:00" }
      }
    end
    assert_redirected_to tenant_rules_path

    rule = AvailabilityRule.last
    assert_nil rule.user_id
    assert_equal "allow", rule.rule_type
  end

  test "admin は固定ブロックを追加できる（ラベル付き）" do
    sign_in @admin
    assert_difference "AvailabilityRule.count", 1 do
      post tenant_rules_path(rule_type: "block"), params: {
        availability_rule: { day_of_week: 3, start_time: "12:00", end_time: "13:00", label: "昼休み" }
      }
    end

    rule = AvailabilityRule.last
    assert_nil rule.user_id
    assert_equal "block", rule.rule_type
    assert_equal "昼休み", rule.label
  end

  test "rule_type はフォーム送信値では決まらない（URLのallowが勝つ）" do
    sign_in @admin
    post tenant_rules_path(rule_type: "allow"), params: {
      availability_rule: { day_of_week: 3, start_time: "10:00", end_time: "18:00", rule_type: "block" }
    }
    assert_equal "allow", AvailabilityRule.last.rule_type
  end

  test "未知の rule_type は 404" do
    sign_in @admin
    get new_tenant_rule_path(rule_type: "destroy_everything")
    assert_response :not_found

    assert_no_difference "AvailabilityRule.count" do
      post tenant_rules_path(rule_type: "hack"), params: {
        availability_rule: { day_of_week: 3, start_time: "10:00", end_time: "18:00" }
      }
    end
    assert_response :not_found
  end

  test "admin でないメンバーはルールを追加できない" do
    sign_in @non_admin
    assert_no_difference "AvailabilityRule.count" do
      post tenant_rules_path(rule_type: "block"), params: {
        availability_rule: { day_of_week: 3, start_time: "12:00", end_time: "13:00" }
      }
    end
    assert_redirected_to root_path
  end

  test "終了時刻が開始時刻以前なら弾く" do
    sign_in @admin
    assert_no_difference "AvailabilityRule.count" do
      post tenant_rules_path(rule_type: "block"), params: {
        availability_rule: { day_of_week: 3, start_time: "13:00", end_time: "12:00" }
      }
    end
    assert_response :unprocessable_entity
  end

  # --- 更新・削除 -------------------------------------------------------------

  test "admin は営業時間を編集できる（rule_type は変わらない）" do
    sign_in @admin
    rule = AvailabilityRule.create!(user_id: nil, day_of_week: 3, start_time: "10:00", end_time: "18:00",
                                     rule_type: "allow")

    patch tenant_rule_path(rule), params: {
      availability_rule: { day_of_week: 3, start_time: "10:00", end_time: "17:00", rule_type: "block" }
    }

    assert_redirected_to tenant_rules_path
    rule.reload
    assert_equal Time.zone.parse("2000-01-01 17:00"), rule.end_time
    assert_equal "allow", rule.rule_type
  end

  test "admin は固定ブロックを編集できる" do
    sign_in @admin
    rule = AvailabilityRule.create!(user_id: nil, day_of_week: 3, start_time: "12:00", end_time: "13:00",
                                     rule_type: "block", label: "昼休み")

    patch tenant_rule_path(rule), params: {
      availability_rule: { day_of_week: 3, start_time: "12:00", end_time: "12:30", label: "昼休み（短縮）" }
    }

    assert_redirected_to tenant_rules_path
    rule.reload
    assert_equal Time.zone.parse("2000-01-01 12:30"), rule.end_time
    assert_equal "昼休み（短縮）", rule.label
  end

  test "admin はルールを削除できる" do
    sign_in @admin
    rule = AvailabilityRule.create!(user_id: nil, day_of_week: 3, start_time: "12:00", end_time: "13:00",
                                     rule_type: "block", label: "昼休み")

    assert_difference "AvailabilityRule.count", -1 do
      delete tenant_rule_path(rule)
    end
    assert_redirected_to tenant_rules_path
  end

  test "この画面からは個人ルールを操作できない（tenant_wide に絞る）" do
    sign_in @admin
    member = User.create!(name: "参加 者", email: "p@example.com", password: "password1234")
    personal_block = AvailabilityRule.create!(user_id: member.id, day_of_week: 3,
      start_time: "12:00", end_time: "13:00", rule_type: "block", label: "個人の予定")

    get edit_tenant_rule_path(personal_block)
    assert_response :not_found

    assert_no_difference "AvailabilityRule.count", -1 do
      delete tenant_rule_path(personal_block)
    end
  end
end

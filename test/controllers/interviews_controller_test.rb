require "test_helper"

# 画面①（面接を組む）＝面接官選択＋週カレンダー（仕様書 §6.6）。
# 空き枠クリックから先（予約フォーム・確定）は次段階。
class InterviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @operator = User.create!(name: "採用 花子", email: "op@example.com", operator: true)
    @iv1 = User.create!(name: "伊藤 一郎", email: "ito@example.com", interviewer: true)
    @iv2 = User.create!(name: "佐藤 次郎", email: "sato@example.com", interviewer: true)

    (1..5).each do |wday|
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "10:00", end_time: "18:00", rule_type: "allow")
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "12:00", end_time: "13:00", rule_type: "block", label: "昼休み")
    end
    @iv1.calendar_events.create!(source: "external", title: "部門定例",
      start_at: Time.zone.parse("2026-09-02 13:00"), end_at: Time.zone.parse("2026-09-02 14:00"))

    post login_path, params: { user_id: @operator.id } # ログイン必須
  end

  test "未ログインなら login へ" do
    reset!
    get new_interview_path
    assert_redirected_to login_path
  end

  test "new：面接官を選ぶ前はフォームだけ、カレンダーは案内文" do
    get new_interview_path
    assert_response :success
    assert_select "input[type=checkbox][name=?]", "user_ids[]", count: 2
    assert_select "select#duration"
    assert_select "turbo-frame#week_calendar", text: /面接官を選んで/
  end

  test "new：面接官を選ぶと週カレンダーが出る" do
    get new_interview_path, params: { user_ids: [ @iv1.id, @iv2.id ], duration: 60,
                                      week_of: "2026-08-31" }
    assert_response :success
    assert_select "turbo-frame#week_calendar .week-grid"
    assert_select ".week-grid__day", count: 7
    # 伊藤の予定がラベル付きで出る
    assert_select ".seg--busy", text: %r{伊藤 一郎／部門定例}
    # 昼休みが予約不可として出る
    assert_select ".seg--blocked", text: /昼休み/
    # 全員空きの帯（クリックは次段）
    assert_select ".seg--free"
  end

  test "calendar：Turbo Frame 部分だけ返す（レイアウト・フォームなし）" do
    get calendar_interviews_path, params: { user_ids: [ @iv1.id ], duration: 60,
                                            week_of: "2026-08-31" }
    assert_response :success
    assert_match(/\A\s*<turbo-frame id="week_calendar">/, @response.body)
    assert_select "h1", count: 0            # 画面①の見出しはレイアウト側なので出ない
    assert_select "form", count: 0          # フォームは差し替え対象外
    assert_select "turbo-frame#week_calendar .week-nav a", text: /翌週/
  end

  test "calendar：interviewer でない id は除外される" do
    get calendar_interviews_path, params: { user_ids: [ @operator.id ], duration: 60 }
    assert_response :success
    assert_select "turbo-frame#week_calendar", text: /面接官が見つかりません/
  end

  test "calendar：壊れた week_of は今週にフォールバックして落ちない" do
    get calendar_interviews_path, params: { user_ids: [ @iv1.id ], week_of: "not-a-date" }
    assert_response :success
  end

  test "週送りリンクは user_ids と duration を引き継ぐ" do
    get calendar_interviews_path, params: { user_ids: [ @iv1.id, @iv2.id ], duration: 45,
                                            week_of: "2026-08-31" }
    assert_select "a[href*=?]", "week_of=2026-09-07" # 翌週
    assert_select "a[href*=?]", "duration=45"
  end
end

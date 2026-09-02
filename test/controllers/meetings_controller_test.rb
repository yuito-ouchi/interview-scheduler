require "test_helper"

# 画面①（ミーティングを組む）＝参加者選択＋週カレンダー（仕様書 §6.6）。
# 空き枠クリックから先（予約フォーム・確定）は次段階。
class MeetingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @operator = User.create!(name: "採用 花子", email: "op@example.com", operator: true)
    @iv1 = User.create!(name: "伊藤 一郎", email: "ito@example.com", participant: true)
    @iv2 = User.create!(name: "佐藤 次郎", email: "sato@example.com", participant: true)

    (1..5).each do |wday|
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "10:00", end_time: "18:00", rule_type: "allow")
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "12:00", end_time: "13:00", rule_type: "block", label: "昼休み")
    end
    @iv1.calendar_events.create!(source: "external", title: "部門定例",
      start_at: Time.zone.parse("2026-09-16 13:00"), end_at: Time.zone.parse("2026-09-16 14:00"))

    post login_path, params: { user_id: @operator.id } # ログイン必須
  end

  test "未ログインなら login へ" do
    reset!
    get new_meeting_path
    assert_redirected_to login_path
  end

  test "new：参加者を選ぶ前はフォームだけ、カレンダーは案内文" do
    get new_meeting_path
    assert_response :success
    assert_select "input[type=checkbox][name=?]", "user_ids[]", count: 2
    assert_select "input#duration_search[type=number]"
    assert_select "turbo-frame#week_calendar", text: /参加者を選んで/
  end

  test "new：参加者を選ぶと週カレンダーが出る" do
    get new_meeting_path, params: { user_ids: [ @iv1.id, @iv2.id ], duration: 60,
                                    week_of: "2026-09-14" }
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
    get calendar_meetings_path, params: { user_ids: [ @iv1.id ], duration: 60,
                                          week_of: "2026-09-14" }
    assert_response :success
    assert_match(/\A\s*<turbo-frame id="week_calendar">/, @response.body)
    assert_select "h1", count: 0            # 画面①の見出しはレイアウト側なので出ない
    assert_select "form", count: 0          # フォームは差し替え対象外
    assert_select "turbo-frame#week_calendar .week-nav a", text: /翌週/
  end

  test "calendar：participant でない id は除外される" do
    get calendar_meetings_path, params: { user_ids: [ @operator.id ], duration: 60 }
    assert_response :success
    assert_select "turbo-frame#week_calendar", text: /参加者が見つかりません/
  end

  test "calendar：壊れた week_of は今週にフォールバックして落ちない" do
    get calendar_meetings_path, params: { user_ids: [ @iv1.id ], week_of: "not-a-date" }
    assert_response :success
  end

  test "週送りリンクは user_ids と duration を引き継ぐ" do
    get calendar_meetings_path, params: { user_ids: [ @iv1.id, @iv2.id ], duration: 45,
                                          week_of: "2026-09-14" }
    assert_select "a[href*=?]", "week_of=2026-09-21" # 翌週
    assert_select "a[href*=?]", "duration=45"
  end

  # --- 予約フォーム（§6.6 手順5）--------------------------------------------
  test "new：空き枠リンク（start_at付き）で予約フォームが開く" do
    get new_meeting_path, params: { user_ids: [ @iv1.id, @iv2.id ], duration: 60,
                                    week_of: "2026-09-14",
                                    start_at: "2026-09-16T10:00:00+09:00",
                                    end_at: "2026-09-16T11:00:00+09:00" }
    assert_response :success
    assert_select "turbo-frame#booking_form .booking" do
      assert_select "input[type=hidden][name=?][value=?]", "date", "2026-09-16"
      assert_select "input[type=time][name=?][value=?]", "start_time", "10:00"
      assert_select "input[type=hidden][name=?]", "user_ids[]", count: 2
      assert_select "input[name=?]", "meeting[guest_name]"
    end
    assert_select ".booking__slot", text: /伊藤 一郎・佐藤 次郎/
  end

  # --- 予約確定（§6.6 手順7 / §5 / A-3）----------------------------------
  BOOK = { guest_name: "山田", location_type: "online" }.freeze

  # 予約フォームは date + start_time + duration から日時を組み立てる（BR-08：
  # 開始5分刻み／所要は分単位で自由）。テストの呼び出し側は従来どおり
  # start_at/end_at の文字列で渡し、ここで新しいパラメータ形に変換する。
  def booking_params(start_at:, end_at:, user_ids:, **over)
    start = Time.zone.parse(start_at)
    finish = Time.zone.parse(end_at)
    {
      meeting: BOOK.merge(over),
      date: start.to_date.iso8601,
      start_time: start.strftime("%H:%M"),
      duration: ((finish - start) / 60).to_i,
      user_ids: user_ids
    }
  end

  test "create：全員空きなら Meeting・出席者・占有を作って詳細へ" do
    post meetings_path, params: booking_params(
      start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
      user_ids: [ @iv1.id, @iv2.id ])

    meeting = Meeting.last
    assert_redirected_to meeting_path(meeting)
    assert_equal "山田", meeting.guest_name
    assert_equal @operator.id, meeting.created_by_id
    assert_equal [ @iv1.id, @iv2.id ].sort, meeting.attendees.pluck(:id).sort

    events = meeting.calendar_events
    assert_equal 2, events.size
    assert(events.all? { |e| e.source == "app" })
    assert(events.all? { |e| e.title == "ミーティング：山田様" }) # BR-11
    assert(events.all? { |e| !e.all_day })
  end

  test "create：確定したミーティングは次の検索で空き枠から外れる（自ダブルブッキング防止）" do
    common = { user_ids: [ @iv1.id, @iv2.id ], duration: 60, week_of: "2026-09-14" }

    get calendar_meetings_path, params: common
    assert_select "a[href*=?]", "start_at=2026-09-16T10%3A00", text: "10:00"

    post meetings_path, params: booking_params(
      start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
      user_ids: [ @iv1.id, @iv2.id ])
    assert_response :redirect

    get calendar_meetings_path, params: common
    assert_select "a[href*=?]", "start_at=2026-09-16T10%3A00", count: 0
    assert_select "a[href*=?]", "start_at=2026-09-16T11%3A00", text: "11:00" # 直後は空き（隣接）
  end

  test "create：1名でも埋まっていれば予約全体を中止（部分確定しない）" do
    # @iv1 は 2026-09-16 13:00-14:00 に「部門定例」あり（setup）
    assert_no_difference [ "Meeting.count", "MeetingAttendee.count", "CalendarEvent.count" ] do
      post meetings_path, params: booking_params(
        start_at: "2026-09-16T13:00:00+09:00", end_at: "2026-09-16T14:00:00+09:00",
        user_ids: [ @iv1.id, @iv2.id ])
    end
    assert_response :unprocessable_entity
    assert_select ".flash-alert", text: /伊藤 一郎.*予定が埋まりました/
    assert_select "input[type=hidden][name=?][value=?]", "date", "2026-09-16"
    assert_select "input[type=time][name=?][value=?]", "start_time", "13:00"
  end

  test "create：過去日時は弾く（§9.3-1）" do
    assert_no_difference "Meeting.count" do
      post meetings_path, params: booking_params(
        start_at: "2020-01-01T10:00:00+09:00", end_at: "2020-01-01T11:00:00+09:00",
        user_ids: [ @iv1.id, @iv2.id ])
    end
    assert_response :unprocessable_entity
    assert_select ".errors", text: /現在より後の日時/
  end

  test "create：ゲスト名が未入力なら弾き、日時・参加者は保持する" do
    assert_no_difference "Meeting.count" do
      post meetings_path, params: booking_params(
        start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
        user_ids: [ @iv1.id, @iv2.id ], guest_name: "")
    end
    assert_response :unprocessable_entity
    assert_select "input[type=hidden][name=?][value=?]", "date", "2026-09-16"
    assert_select "input[type=time][name=?][value=?]", "start_time", "10:00"
    assert_select "input[type=hidden][name=?]", "user_ids[]", count: 2
  end

  test "show：出席者と占有件数を表示する" do
    post meetings_path, params: booking_params(
      start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
      user_ids: [ @iv1.id, @iv2.id ])
    follow_redirect!
    assert_response :success
    assert_select "dd", text: /伊藤 一郎・佐藤 次郎/
    assert_select ".hint", text: /2 件作成/
  end
end

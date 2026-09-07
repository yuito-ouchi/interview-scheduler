require "test_helper"

# 画面①（ミーティングを組む）＝参加者選択＋週カレンダー（仕様書 §6.6）。
# 空き枠クリックから先（予約フォーム・確定）は次段階。
class MeetingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @member = User.create!(name: "採用 花子", email: "op@example.com", password: "password1234")
    @iv1 = User.create!(name: "伊藤 一郎", email: "ito@example.com", password: "password1234")
    @iv2 = User.create!(name: "佐藤 次郎", email: "sato@example.com", password: "password1234")

    (1..5).each do |wday|
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "10:00", end_time: "18:00", rule_type: "allow")
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "12:00", end_time: "13:00", rule_type: "block", label: "昼休み")
    end
    @iv1.calendar_events.create!(source: "external", title: "部門定例",
      start_at: Time.zone.parse("2026-09-16 13:00"), end_at: Time.zone.parse("2026-09-16 14:00"))

    sign_in @member # ログイン必須（判断メモ D-12：Devise::Test::IntegrationHelpers）
  end

  test "未ログインなら login へ" do
    reset!
    get new_meeting_path
    assert_redirected_to new_user_session_path
  end

  test "new：参加者を選ぶ前はフォームだけ、カレンダーは案内文" do
    get new_meeting_path
    assert_response :success
    # D-15：メンバー全員が候補に並ぶ。ログイン中の主催者（@member）自身も含めて3名
    assert_select "input[type=checkbox][name=?]", "user_ids[]", count: 3
    assert_select "input#duration_search[type=number]"
    assert_select "turbo-frame#week_calendar", text: /参加者を1名以上選んで/
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

  test "calendar：Turbo Frame 部分だけ返す（ページの見出しは含まない）" do
    get calendar_meetings_path, params: { user_ids: [ @iv1.id ], duration: 60,
                                          week_of: "2026-09-14" }
    assert_response :success
    assert_match(/\A\s*<turbo-frame id="week_calendar">/, @response.body)
    assert_select "h1", count: 0 # 画面①の見出しはレイアウト側なので出ない
    # サイドバーの参加者選択フォームはこのフレームの内側にある（自分自身を
    # 更新する形にしているため、離れたフレームを狙う形と違い連続操作でも
    # 取りこぼされない。§6.4）。
    assert_select "turbo-frame#week_calendar form#slot_form"
    assert_select "turbo-frame#week_calendar .week-nav a", text: /翌週/
  end

  test "calendar：存在しない id は除外される" do
    get calendar_meetings_path, params: { user_ids: [ User.maximum(:id) + 1 ], duration: 60 }
    assert_response :success
    assert_select "turbo-frame#week_calendar", text: /参加者が見つかりません/
  end

  test "calendar：主催者自身もメンバーとして選べる（D-15）" do
    get calendar_meetings_path, params: { user_ids: [ @member.id ], duration: 60 }
    assert_response :success
    assert_select ".week-nav__label", text: /採用 花子/
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
    assert_equal @member.id, meeting.created_by_id
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
    # 空き帯そのものがクリック対象（a.seg--free）。href は帯の先頭時刻。
    assert_select "a.seg--free[href*=?]", "start_at=2026-09-16T10%3A00"

    post meetings_path, params: booking_params(
      start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
      user_ids: [ @iv1.id, @iv2.id ])
    assert_response :redirect

    get calendar_meetings_path, params: common
    assert_select "a.seg--free[href*=?]", "start_at=2026-09-16T10%3A00", count: 0
    assert_select "a.seg--free[href*=?]", "start_at=2026-09-16T11%3A00" # 直後は空き（隣接）
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

  test "show：出席者を表示する" do
    post meetings_path, params: booking_params(
      start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
      user_ids: [ @iv1.id, @iv2.id ])
    follow_redirect!
    assert_response :success
    assert_select "dd", text: /伊藤 一郎・佐藤 次郎/
    # 占有（calendar_events）は画面に出さないが、作られていること自体は確認する
    assert_equal 2, Meeting.last.calendar_events.count
  end

  # --- 一覧・変更・キャンセル（F-24〜F-26）--------------------------------
  def create_meeting!(start_at:, end_at:, user_ids: [ @iv1.id, @iv2.id ], guest_name: "山田")
    post meetings_path, params: booking_params(start_at: start_at, end_at: end_at,
                                                user_ids: user_ids, guest_name: guest_name)
    Meeting.last
  end

  test "index：登録者で絞り込まず今後の予約を表示する（§6.7・§9.1）" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")
    get meetings_path
    assert_response :success
    assert_select ".meetings-table", text: /山田/
    assert_select ".meetings-table", text: /伊藤 一郎・佐藤 次郎/
    assert_select "a[href=?]", meeting_path(meeting)
  end

  # --- 予約一覧の検索（D-10）--------------------------------------------------
  test "index：ゲスト名で検索できる" do
    yamada = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
                              guest_name: "山田")
    create_meeting!(start_at: "2026-09-16T13:00:00+09:00", end_at: "2026-09-16T13:30:00+09:00",
                     guest_name: "鈴木")

    get meetings_path, params: { q: "山田" }

    assert_select "a[href=?]", meeting_path(yamada)
    assert_select ".meetings-table", text: /鈴木/, count: 0
  end

  test "index：参加者名で検索できる" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00",
                               user_ids: [ @iv1.id ]) # 伊藤 一郎
    other = create_meeting!(start_at: "2026-09-16T13:00:00+09:00", end_at: "2026-09-16T13:30:00+09:00",
                             user_ids: [ @iv2.id ]) # 佐藤 次郎

    get meetings_path, params: { q: "伊藤" }

    assert_select "a[href=?]", meeting_path(meeting)
    assert_select "a[href=?]", meeting_path(other), count: 0
  end

  test "index：登録者名で検索できる" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    get meetings_path, params: { q: "花子" } # created_by は @member（採用 花子）

    assert_select "a[href=?]", meeting_path(meeting)
  end

  test "index：一致しない検索語なら一覧を空にして案内文を出す" do
    create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    get meetings_path, params: { q: "存在しないキーワード" }

    assert_select ".meetings-table", count: 0
    assert_select ".hint", text: /存在しないキーワード.*一致する今後の予約はありません/
  end

  test "edit：現在の日時・所要時間・ゲスト情報を表示する" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")
    get edit_meeting_path(meeting)
    assert_response :success
    assert_select "input[value=?]", "2026-09-16"
    assert_select "input[value=?]", "10:00"
    assert_select "input[value=?]", "60"
  end

  # --- 予約変更をカレンダーから調整（D-9）------------------------------------
  test "edit：週カレンダーが出て、自分自身の予定は空き扱いになる" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")
    get edit_meeting_path(meeting)
    assert_response :success
    assert_select ".week-grid"
    # 自分自身の占有（calendar_events）を除外しないと、自分の予定と重なる＝
    # 不可になり、今の時間帯にすら戻せなくなる（confirm_update と同じ理由）。
    assert_select "a.seg--free[href*=?]", "start_at=2026-09-16T10%3A00"
  end

  test "edit：予約不可時間（block）や他の予定も新規予約と同じように表示される" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")
    get edit_meeting_path(meeting)
    assert_response :success
    # テナント全体の block（setup の「昼休み」12:00-13:00）
    assert_select ".seg--blocked", text: /昼休み/
    # 出席者（@iv1）の他の予定（部門定例 13:00-14:00・setup）
    assert_select ".seg--busy", text: %r{伊藤 一郎／部門定例}
  end

  test "edit：カレンダーの空き帯クリック相当（start_at付き）でフォームの日時が差し替わる（保存はしない）" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    get edit_meeting_path(meeting), params: {
      week_of: "2026-09-14", duration: 60,
      start_at: "2026-09-16T14:00:00+09:00", end_at: "2026-09-16T15:00:00+09:00"
    }

    assert_response :success
    assert_select "input[type=time][name=?][value=?]", "start_time", "14:00"
    meeting.reload
    assert_equal Time.zone.parse("2026-09-16T10:00:00+09:00"), meeting.start_at # まだ保存していない
  end

  test "update：日時を変えずに再送しても自分自身とはぶつからず更新できる" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    patch meeting_path(meeting), params: {
      date: "2026-09-16", start_time: "10:00", duration: 60,
      meeting: { guest_name: "山田（改）", location_type: "online" }
    }

    assert_redirected_to meeting
    meeting.reload
    assert_equal "山田（改）", meeting.guest_name
    assert(meeting.calendar_events.all? { |e| e.title == "ミーティング：山田（改）様" })
  end

  test "update：他の予定とぶつかる日時には変更できない（再判定）" do
    # @iv1 は 2026-09-16 13:00-14:00 に「部門定例」あり（setup）
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    assert_no_changes -> { meeting.reload.start_at } do
      patch meeting_path(meeting), params: {
        date: "2026-09-16", start_time: "13:00", duration: 60,
        meeting: { guest_name: "山田", location_type: "online" }
      }
    end

    assert_response :unprocessable_entity
    assert_select ".flash-alert", text: /伊藤 一郎.*予定が埋まりました/
  end

  # --- 変更画面での参加者の選び直し（判断メモ D-14）--------------------------

  test "edit：user_ids を渡さなければ現在の出席者が選択された状態で表示される" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    get edit_meeting_path(meeting)

    assert_response :success
    assert_select "input[type=checkbox][name=?][value=?][checked=checked]", "user_ids[]", @iv1.id.to_s
    assert_select "input[type=checkbox][name=?][value=?][checked=checked]", "user_ids[]", @iv2.id.to_s
  end

  test "edit：user_ids を渡すと、その参加者でカレンダーを引き直す（保存はしない）" do
    iv3 = User.create!(name: "鈴木 三郎", email: "suzuki@example.com", password: "password1234",
                        )
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    get edit_meeting_path(meeting), params: { week_of: "2026-09-14", duration: 60, user_ids: [ iv3.id ] }

    assert_response :success
    assert_select ".week-nav__label", text: /鈴木 三郎/
    # @iv1 の「部門定例」は対象外になるので消える
    assert_select ".seg--busy", text: %r{伊藤 一郎／部門定例}, count: 0
    # まだ保存していない
    assert_equal [ @iv1.id, @iv2.id ].sort, meeting.reload.attendees.map(&:id).sort
  end

  test "edit：全員のチェックを外した状態（空の user_ids のみ）も表現できる" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    get edit_meeting_path(meeting), params: { user_ids: [ "" ] }

    assert_response :success
    assert_select ".hint", text: /参加者を1名以上選んでください/
  end

  test "update：参加者を追加すると出席者と占有（calendar_events）が増える" do
    iv3 = User.create!(name: "鈴木 三郎", email: "suzuki@example.com", password: "password1234",
                        )
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    assert_difference "MeetingAttendee.count", 1 do
      assert_difference "CalendarEvent.count", 1 do
        patch meeting_path(meeting), params: {
          date: "2026-09-16", start_time: "10:00", duration: 60,
          user_ids: [ "", @iv1.id, @iv2.id, iv3.id ],
          meeting: { guest_name: "山田", location_type: "online" }
        }
      end
    end

    assert_redirected_to meeting
    meeting.reload
    assert_equal [ @iv1.id, @iv2.id, iv3.id ].sort, meeting.attendees.map(&:id).sort
    # 追加した人の占有も source: "app" ＋ meeting_id 付きで作られる（設計判断3）
    added = meeting.calendar_events.find_by(user_id: iv3.id)
    assert_equal "app", added.source
    assert_equal "ミーティング：山田様", added.title
    assert_equal Time.zone.parse("2026-09-16 10:00"), added.start_at
  end

  test "update：参加者を外すとその人の出席者・占有が消える" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    assert_difference "MeetingAttendee.count", -1 do
      assert_difference "CalendarEvent.count", -1 do
        patch meeting_path(meeting), params: {
          date: "2026-09-16", start_time: "10:00", duration: 60,
          user_ids: [ "", @iv1.id ],
          meeting: { guest_name: "山田", location_type: "online" }
        }
      end
    end

    assert_redirected_to meeting
    meeting.reload
    assert_equal [ @iv1.id ], meeting.attendees.map(&:id)
    # 外した人のカレンダーにこのミーティングの占有が残っていない
    assert_nil CalendarEvent.find_by(meeting_id: meeting.id, user_id: @iv2.id)
  end

  test "update：追加した参加者が埋まっていれば変更全体を中止する（BR-06）" do
    iv3 = User.create!(name: "鈴木 三郎", email: "suzuki@example.com", password: "password1234",
                        )
    iv3.calendar_events.create!(source: "external", title: "終日研修",
      start_at: Time.zone.parse("2026-09-16 10:00"), end_at: Time.zone.parse("2026-09-16 11:00"))
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    assert_no_difference [ "MeetingAttendee.count", "CalendarEvent.count" ] do
      patch meeting_path(meeting), params: {
        date: "2026-09-16", start_time: "10:00", duration: 60,
        user_ids: [ "", @iv1.id, @iv2.id, iv3.id ],
        meeting: { guest_name: "山田（改）", location_type: "online" }
      }
    end

    assert_response :unprocessable_entity
    assert_select ".flash-alert", text: /鈴木 三郎.*予定が埋まりました/
    # 部分確定しない：ゲスト名の変更も含めて何も保存されない
    meeting.reload
    assert_equal "山田", meeting.guest_name
    assert_equal [ @iv1.id, @iv2.id ].sort, meeting.attendees.map(&:id).sort
  end

  test "update：参加者を1人も選ばないと弾く" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    assert_no_difference "MeetingAttendee.count" do
      patch meeting_path(meeting), params: {
        date: "2026-09-16", start_time: "10:00", duration: 60,
        user_ids: [ "" ],
        meeting: { guest_name: "山田", location_type: "online" }
      }
    end

    assert_response :unprocessable_entity
    assert_select ".flash-alert", text: /参加者が選択されていません/
  end

  test "update：user_ids を送らないリクエストでは参加者を現状維持にする" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    assert_no_difference [ "MeetingAttendee.count", "CalendarEvent.count" ] do
      patch meeting_path(meeting), params: {
        date: "2026-09-16", start_time: "15:00", duration: 60,
        meeting: { guest_name: "山田", location_type: "online" }
      }
    end

    assert_redirected_to meeting
    meeting.reload
    assert_equal [ @iv1.id, @iv2.id ].sort, meeting.attendees.map(&:id).sort
    assert_equal Time.zone.parse("2026-09-16 15:00"), meeting.start_at
  end

  test "update：存在しない user_id は無視される" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    patch meeting_path(meeting), params: {
      date: "2026-09-16", start_time: "10:00", duration: 60,
      user_ids: [ "", @iv1.id, User.maximum(:id) + 1 ],
      meeting: { guest_name: "山田", location_type: "online" }
    }

    assert_redirected_to meeting
    assert_equal [ @iv1.id ], meeting.reload.attendees.map(&:id)
  end

  test "update：過去日時には変更できない（§9.3-1 と同じ穴を update でも塞ぐ）" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    patch meeting_path(meeting), params: {
      date: "2020-01-01", start_time: "10:00", duration: 60,
      meeting: { guest_name: "山田", location_type: "online" }
    }

    assert_response :unprocessable_entity
    assert_select ".errors", text: /現在より後の日時/
  end

  test "destroy：キャンセルすると占有（calendar_events）も連動して消える" do
    meeting = create_meeting!(start_at: "2026-09-16T10:00:00+09:00", end_at: "2026-09-16T11:00:00+09:00")

    assert_difference "Meeting.count", -1 do
      assert_difference "MeetingAttendee.count", -2 do
        assert_difference "CalendarEvent.count", -2 do
          delete meeting_path(meeting)
        end
      end
    end

    assert_redirected_to meetings_path
  end
end

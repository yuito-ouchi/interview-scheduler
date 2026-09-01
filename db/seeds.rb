# 判定ロジック（AvailabilityChecker / WeeklySlotFinder）を試すためのダミーデータ。
# 予定はすべて source: "external"（H-15：同期済みの前提）。
# 時刻は必ず Time.zone.parse で生成する（CLAUDE.md / 別紙A A-1 のTZ規約）。
#
# 「今週」＝実行日の属する週。月曜起点で相対生成するため、いつ実行しても
# 今週〜来週にデータが入る。

# --- 冪等化：FK 依存の逆順に全消し ---------------------------------------
[InterviewAttendee, CalendarEvent, Interview, AvailabilityRule, User].each(&:delete_all)

# --- メンバー ----------------------------------------------------------
# 採用担当者2名（うち1名は面接にも出る兼任）
op1 = User.create!(name: "採用 花子", email: "hanako@example.com", operator: true,  interviewer: true)
op2 = User.create!(name: "調整 太郎", email: "taro@example.com",   operator: true,  interviewer: false)

# 面接実施者4名
iv1 = User.create!(name: "伊藤 一郎", email: "ito@example.com",    interviewer: true)
iv2 = User.create!(name: "佐藤 次郎", email: "sato@example.com",   interviewer: true)
iv3 = User.create!(name: "鈴木 三郎", email: "suzuki@example.com", interviewer: true)
iv4 = User.create!(name: "田中 四郎", email: "tanaka@example.com", interviewer: true)

# --- テナント全体の営業時間ルール（user_id: nil）----------------------
# 平日 10:00-18:00 を allow、12:00-13:00 を block（昼休み）
(1..5).each do |wday| # 1=月 .. 5=金
  AvailabilityRule.create!(user_id: nil, day_of_week: wday,
                           start_time: "10:00", end_time: "18:00", rule_type: "allow")
  AvailabilityRule.create!(user_id: nil, day_of_week: wday,
                           start_time: "12:00", end_time: "13:00", rule_type: "block", label: "昼休み")
end

# --- 既存予定 --------------------------------------------------------
monday = Date.current.beginning_of_week           # 今週の月曜
day    = ->(n) { (monday + n.days).to_s }         # n=0..4 今週, 7..11 来週
ev = lambda do |user, title, n, from, to, all_day: false|
  CalendarEvent.create!(
    user: user, source: "external", title: title, all_day: all_day,
    start_at: Time.zone.parse("#{day.(n)} #{from}"),
    end_at:   Time.zone.parse("#{day.(n)} #{to}")
  )
end

# ▼ 境界条件の検証用に、水曜(n=2) 14:00-15:00（60分）を「基準の要求区間」として配置する。
#   別紙A A-2-5 のケース番号を右に付す。
ev.(iv1, "部門定例",   2, "13:00", "14:00")           # case1 隣接（既存終了=要求開始）→ 空き
ev.(iv1, "1on1",       2, "15:00", "16:00")           # case2 隣接（既存開始=要求終了）→ 空き
ev.(iv4, "採用会議",   2, "13:30", "14:30")           # case5 前方で部分的に重なる → 不可
ev.(iv2, "面談",       2, "14:30", "15:30")           # case6 後方で部分的に重なる → 不可
ev.(iv3, "電話",       2, "14:00", "14:30")           # case4 要求が既存を完全に含む → 不可

# ▼ 火曜(n=1) は iv1 が終日ふさがる長時間予定。火曜 14:00-15:00 を要求すると
#   case3（既存が要求を完全に含む）。かつ 09:00-19:00 で「営業時間をまたぐ予定」。
ev.(iv1, "社外研修",   1, "09:00", "19:00")           # case3 / 営業時間をまたぐ

# ▼ 木曜(n=3) は iv1 が終日予定（case7）
ev.(iv1, "有給",       3, "00:00", "23:59", all_day: true) # case7 終日予定

# ▼ その他の予定（一覧・週カレンダー表示の見た目確認用）
ev.(iv3, "レビュー",       0, "16:00", "17:00")       # 今週 月
ev.(op1, "1on1",           3, "11:00", "12:00")       # 今週 木
ev.(iv2, "チームMTG",      4, "10:00", "12:00")       # 今週 金
ev.(iv1, "週次",           7, "10:00", "11:00")       # 来週 月
ev.(iv4, "顧客訪問",       8, "10:00", "11:00")       # 来週 火
ev.(op1, "面接(他候補)",   9, "15:00", "16:00")       # 来週 水
ev.(iv2, "部門定例",      10, "13:00", "14:00")       # 来週 木
ev.(iv3, "作業ブロック",  11, "14:00", "17:00")       # 来週 金

# --- サマリ ---------------------------------------------------------
puts "seed 完了"
puts "  users: #{User.count}（operator: #{User.operators.count} / interviewer: #{User.interviewers.count}）"
puts "  availability_rules: #{AvailabilityRule.count}（allow #{AvailabilityRule.allows.count} / block #{AvailabilityRule.blocks.count}, すべてテナント全体）"
puts "  calendar_events: #{CalendarEvent.count}（うち終日 #{CalendarEvent.where(all_day: true).count}, すべて external）"
puts "  今週の月曜 = #{monday}"
puts "  基準の要求区間: 水曜 #{day.(2)} 14:00-15:00 に対し case1-7 を iv1-iv4 に配置済み"

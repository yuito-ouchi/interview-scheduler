require "test_helper"

# 週カレンダーの空き枠算出（仕様書 §6.6 ／ 別紙A A-2-3・A-2-4）。
class WeeklySlotFinderTest < ActiveSupport::TestCase
  # 2026-08-31（月）〜 09-06（日）の週。水曜 = 09-02。
  MONDAY = Date.new(2026, 8, 31)

  setup do
    @tenant_rules = []
    (1..5).each do |wday|
      @tenant_rules << AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "10:00", end_time: "18:00", rule_type: "allow")
      @tenant_rules << AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "12:00", end_time: "13:00", rule_type: "block", label: "昼休み")
    end
    @a = User.create!(name: "面接 A", email: "a@example.com", interviewer: true)
    @b = User.create!(name: "面接 B", email: "b@example.com", interviewer: true)
  end

  def finder(users, duration: 60, week_of: MONDAY)
    loaded = User.where(id: users.map(&:id))
                 .includes(:availability_rules, :calendar_events)
                 .to_a
    WeeklySlotFinder.new(users: loaded, week_of: week_of, duration_min: duration,
                         tenant_rules: @tenant_rules)
  end

  def event!(user, day, from, to, all_day: false, title: "予定")
    user.calendar_events.create!(source: "external", title: title, all_day: all_day,
      start_at: Time.zone.parse("#{day} #{from}"), end_at: Time.zone.parse("#{day} #{to}"))
  end

  test "7日分の Day を返す" do
    days = finder([ @a ]).call
    assert_equal 7, days.size
    assert_equal (MONDAY..MONDAY + 6).to_a, days.map(&:date)
  end

  test "土日は closed で枠なし（テナント allow なし）" do
    days = finder([ @a ]).call
    sat = days.find { |d| d.date == Date.new(2026, 9, 5) }
    sun = days.find { |d| d.date == Date.new(2026, 9, 6) }
    assert sat.closed?
    assert sun.closed?
    assert_empty sat.free_windows
  end

  test "予定もルール違反もない平日は 10:00〜昼休み前 と 昼休み後〜18:00 が空き帯になる" do
    wed = finder([ @a ]).call.find { |d| d.date == Date.new(2026, 9, 2) }

    assert_equal 2, wed.free_windows.size, "昼休み(12-13)で午前と午後に割れる"
    am, pm = wed.free_windows
    assert_equal Time.zone.parse("2026-09-02 10:00"), am[:start_at]
    assert_equal Time.zone.parse("2026-09-02 12:00"), am[:end_at]
    assert_equal Time.zone.parse("2026-09-02 13:00"), pm[:start_at]
    assert_equal Time.zone.parse("2026-09-02 18:00"), pm[:end_at]
  end

  test "15. 営業時間外の枠を返さない（最後の空き帯の終端が営業終了を超えない）" do
    finder([ @a ]).call.reject(&:closed?).each do |day|
      day.free_windows.each do |w|
        assert w[:end_at] <= day.open_to, "#{day.date} の枠が営業終了 #{day.open_to} を超えている"
        assert w[:start_at] >= day.open_from
      end
    end
  end

  test "予定のある区間は空き帯から外れ、その前後は残る（隣接は空き）" do
    event!(@a, "2026-09-02", "14:00", "15:00", title: "面談")
    windows = finder([ @a ]).call.find { |d| d.date == Date.new(2026, 9, 2) }.free_windows

    # 14:00 に終わる枠（13:00-14:00）までは置ける＝午後帯は 13:00 開始・14:00 終了で切れる
    early = windows.find { |w| w[:start_at] == Time.zone.parse("2026-09-02 13:00") }
    assert_equal Time.zone.parse("2026-09-02 14:00"), early[:end_at]

    # 予定の直後 15:00 開始から再開し、18:00 まで
    late = windows.find { |w| w[:start_at] == Time.zone.parse("2026-09-02 15:00") }
    assert_equal Time.zone.parse("2026-09-02 18:00"), late[:end_at]

    # 予定に重なる枠（例：13:30-14:30）は含まれない
    assert_nil windows.find { |w| w[:start_at] == Time.zone.parse("2026-09-02 13:30") }
  end

  test "16. 2名選択で片方だけ埋まっている区間は空き帯に含まれない" do
    event!(@b, "2026-09-02", "14:00", "15:00", title: "他案件")
    windows = finder([ @a, @b ]).call.find { |d| d.date == Date.new(2026, 9, 2) }.free_windows

    covering = windows.find { |w| w[:start_at] <= Time.zone.parse("2026-09-02 14:00") && w[:end_at] > Time.zone.parse("2026-09-02 14:00") }
    assert_nil covering, "B が埋まっている 14:00 台を含む空き帯があってはならない"
  end

  test "終日予定のある日は空き帯が消える" do
    event!(@a, "2026-09-02", "00:00", "23:59", all_day: true, title: "有給")
    wed = finder([ @a ]).call.find { |d| d.date == Date.new(2026, 9, 2) }
    assert_empty wed.free_windows
  end

  test "A-2-4：preload 済みなら call 中に1クエリも発行しない（区間ごとにDBを叩かない）" do
    event!(@a, "2026-09-02", "14:00", "15:00")
    @a.availability_rules.create!(day_of_week: 3, start_time: "15:30", end_time: "16:00",
      rule_type: "block", label: "通院")
    f = finder([ @a, @b ])

    assert_equal 0, count_queries { f.call }
  end

  private

  def count_queries
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      count += 1 unless payload[:name] == "SCHEMA" || sql.match?(/\A\s*(BEGIN|COMMIT|RELEASE|SAVEPOINT|PRAGMA)/i)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
